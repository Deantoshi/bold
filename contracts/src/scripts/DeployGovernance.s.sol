// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

import {Script} from "forge-std/Script.sol";

import {PoolManager, Deployers, Hooks} from "v4-core/test/utils/Deployers.sol";
import {ICurveStableswapFactoryNG} from "V2-gov/src/interfaces/ICurveStableswapFactoryNG.sol";
import {ICurveStableswapNG} from "V2-gov/src/interfaces/ICurveStableswapNG.sol";
import {ILiquidityGauge} from "V2-gov/src/interfaces/ILiquidityGauge.sol";

import {IGovernance} from "V2-gov/src/interfaces/IGovernance.sol";

import {Governance} from "V2-gov/src/Governance.sol";
import {UniV4Donations} from "V2-gov/src/UniV4Donations.sol";
import {CurveV2GaugeRewards} from "V2-gov/src/CurveV2GaugeRewards.sol";
import {Hooks} from "V2-gov/src/utils/BaseHook.sol";

import {MockStakingV1} from "V2-gov/test/mocks/MockStakingV1.sol";
import {HookMiner} from "V2-gov/script/utils/HookMiner.sol";

import {ERC20Faucet} from "../test/TestContracts/ERC20Faucet.sol";

import "forge-std/console2.sol";

contract DeployGovernance is Script, Deployers {
    using Strings for *;

    // Environment Constants
    ERC20Faucet private lqty;
    IERC20 private boldToken;
    address private stakingV1;
    IERC20 private usdc;

    PoolManager private constant poolManager = PoolManager(0xE8E23e97Fa135823143d6b9Cba9c699040D51F70);
    ICurveStableswapFactoryNG private constant curveFactory =
        ICurveStableswapFactoryNG(address(0xfb37b8D939FFa77114005e61CFc2e543d6F49A81));

    // Governance Constants
    uint128 private constant REGISTRATION_FEE = 100e18;
    uint128 private constant REGISTRATION_THRESHOLD_FACTOR = 0.001e18;
    uint128 private constant UNREGISTRATION_THRESHOLD_FACTOR = 3e18;
    uint16 private constant REGISTRATION_WARM_UP_PERIOD = 4;
    uint16 private constant UNREGISTRATION_AFTER_EPOCHS = 4;
    uint128 private constant VOTING_THRESHOLD_FACTOR = 0.03e18;
    uint88 private constant MIN_CLAIM = 500e18;
    uint88 private constant MIN_ACCRUAL = 1000e18;
    uint32 private constant EPOCH_DURATION = 6 days;
    uint32 private constant EPOCH_VOTING_CUTOFF = 1 days;

    // UniV4Donations Constants
    uint256 private immutable VESTING_EPOCH_START = block.timestamp;
    uint256 private constant VESTING_EPOCH_DURATION = 7 days;
    uint24 private constant FEE = 400;
    int24 constant MAX_TICK_SPACING = 32767;

    // CurveV2GaugeRewards Constants
    uint256 private constant DURATION = 7 days;

    // Contracts
    Governance private governance;
    address[] private initialInitiatives;
    UniV4Donations private uniV4Donations;
    CurveV2GaugeRewards private curveV2GaugeRewards;
    ICurveStableswapNG private curvePool;
    ILiquidityGauge private gauge;

    function deployGovernance(address _deployer, bytes32 _salt, IERC20 _boldToken, IERC20 _usdc, ICurveStableswapNG _curvePool) internal returns (address, string memory) {
        deployEnvironment(_boldToken, _usdc);

        curvePool = _curvePool;

        (address governanceAddress, IGovernance.Configuration memory governanceConfiguration) =
            computeGovernanceAddressAndConfig(_deployer, _salt);

        governance = new Governance{salt: _salt}(
            address(lqty),
            address(boldToken),
            stakingV1,
            address(boldToken),
            governanceConfiguration,
            _deployer,
            initialInitiatives
        );

        //console2.log("");
        //console2.log(governance.owner(), "governance.owner()");
        //console2.log(address(governance), "address(governance)");
        //console2.log(governanceAddress, "governanceAddress");
        assert(governanceAddress == address(governance));
        // Uni V4 initiative
        deployUniV4Donations(governance);

        // Curve initiative
        //deployCurveV2GaugeRewards(governance);

        governance.registerInitialInitiatives(initialInitiatives);

        return (governanceAddress, _getManifestJson());
    }

    function computeGovernanceAddress(address _deployer, bytes32 _salt) internal view returns (address) {
        (address governanceAddress,) = computeGovernanceAddressAndConfig(_deployer, _salt);
        return governanceAddress;
    }

    function computeGovernanceAddressAndConfig(address _deployer, bytes32 _salt)
        internal
        view
        returns (address, IGovernance.Configuration memory)
    {
        IGovernance.Configuration memory governanceConfiguration = IGovernance.Configuration({
            registrationFee: REGISTRATION_FEE,
            registrationThresholdFactor: REGISTRATION_THRESHOLD_FACTOR,
            unregistrationThresholdFactor: UNREGISTRATION_THRESHOLD_FACTOR,
            registrationWarmUpPeriod: REGISTRATION_WARM_UP_PERIOD,
            unregistrationAfterEpochs: UNREGISTRATION_AFTER_EPOCHS,
            votingThresholdFactor: VOTING_THRESHOLD_FACTOR,
            minClaim: MIN_CLAIM,
            minAccrual: MIN_ACCRUAL,
            epochStart: uint32(block.timestamp - VESTING_EPOCH_START),
            /// @audit Ensures that `initialInitiatives` can be voted on
            epochDuration: EPOCH_DURATION,
            epochVotingCutoff: EPOCH_VOTING_CUTOFF
        });
        bytes memory bytecode = abi.encodePacked(
            type(Governance).creationCode,
            abi.encode(
                address(lqty),
                address(boldToken),
                stakingV1,
                address(boldToken),
                governanceConfiguration,
                _deployer,
                initialInitiatives
            )
        );
        address governanceAddress = vm.computeCreate2Address(_salt, keccak256(bytecode));

        return (governanceAddress, governanceConfiguration);
    }

    function deployEnvironment(IERC20 _boldToken, IERC20 _usdc) private {
        boldToken = _boldToken;
        usdc = _usdc;
        lqty = new ERC20Faucet("Liquity", "LQTY", 100 ether, 1 days);
        stakingV1 = address(new MockStakingV1(address(lqty)));
    }

    function deployUniV4Donations(IGovernance _governance) private {
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG);

        (, bytes32 salt) = HookMiner.find(
            0x4e59b44847b379578588920cA78FbF26c0B4956C,
            // address(this),
            flags,
            type(UniV4Donations).creationCode,
            abi.encode(
                address(_governance),
                address(boldToken),
                address(lqty),
                block.timestamp,
                EPOCH_DURATION,
                address(poolManager),
                address(usdc),
                FEE,
                MAX_TICK_SPACING
            )
        );

        uniV4Donations = new UniV4Donations{salt: salt}(
            address(_governance),
            address(boldToken),
            address(lqty),
            block.timestamp,
            EPOCH_DURATION,
            address(poolManager),
            address(usdc),
            FEE,
            MAX_TICK_SPACING
        );

        assert(address(governance) == address(uniV4Donations.governance()));
        initialInitiatives.push(address(uniV4Donations));
    }

    function deployCurveV2GaugeRewards(IGovernance _governance) private {
        gauge = ILiquidityGauge(curveFactory.deploy_gauge(address(curvePool)));

        curveV2GaugeRewards =
            new CurveV2GaugeRewards(address(_governance), address(boldToken), address(lqty), address(gauge), DURATION);

        // add BOLD as reward token
        gauge.add_reward(address(boldToken), address(curveV2GaugeRewards));

        initialInitiatives.push(address(curveV2GaugeRewards));
    }

    function _getGovernanceDeploymentConstants() internal pure returns (string memory) {
        return string.concat(
            "{",
            string.concat(
                string.concat('"REGISTRATION_FEE":"', uint256(REGISTRATION_FEE).toString(), '",'),
                string.concat('"REGISTRATION_THRESHOLD_FACTOR":"', uint256(REGISTRATION_THRESHOLD_FACTOR).toString(), '",'),
                string.concat('"UNREGISTRATION_THRESHOLD_FACTOR":"', uint256(UNREGISTRATION_THRESHOLD_FACTOR).toString(), '",'),
                string.concat('"REGISTRATION_WARM_UP_PERIOD":"', uint256(REGISTRATION_WARM_UP_PERIOD).toString(), '",'),
                string.concat('"UNREGISTRATION_AFTER_EPOCHS":"', uint256(UNREGISTRATION_AFTER_EPOCHS).toString(), '",'),
                string.concat('"VOTING_THRESHOLD_FACTOR":"', uint256(VOTING_THRESHOLD_FACTOR).toString(), '",'),
                string.concat('"MIN_CLAIM":"', uint256(MIN_CLAIM).toString(), '",'),
                string.concat('"MIN_ACCRUAL":"', uint256(MIN_ACCRUAL).toString(), '",'),
                string.concat('"EPOCH_DURATION":"', uint256(EPOCH_DURATION).toString(), '",'),
                string.concat('"EPOCH_VOTING_CUTOFF":"', uint256(EPOCH_VOTING_CUTOFF).toString(), '" ') // no comma
            ),
            "}"
        );
    }

    function _getManifestJson() internal view returns (string memory) {
        return string.concat(
            "{",
            string.concat(
                //string.concat('"constants":', _getGovernanceDeploymentConstants(), ","),
                string.concat('"governance":"', address(governance).toHexString(), '",'),
                string.concat('"uniV4DonationsInitiative":"', address(uniV4Donations).toHexString(), '",'),
                string.concat('"curveV2GaugeRewardsInitiative":"', address(curveV2GaugeRewards).toHexString(), '",'),
                string.concat('"curvePool":"', address(curvePool).toHexString(), '",'),
                string.concat('"gauge":"', address(gauge).toHexString(), '",'),
                string.concat('"LQTYToken":"', address(lqty).toHexString(), '" ') // no comma
            ),
            "}"
        );
    }
}
