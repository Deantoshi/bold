#!/bin/bash
# # place in same folder as run-latest.json
# # TO RUN:
# # when pasted in same folder as run-latest.json, make sure you are cd'd into that folder hosting the two and then run the following:
# # chmod +x verify-all-contracts.sh
# # ./verify-all-contracts.sh


# Default delay between verification requests (in seconds)
DELAY=10
# Default compiler version
COMPILER_VERSION=""

# Process command line arguments
while getopts "f:d:c:" opt; do
  case $opt in
    f) JSON_FILE="$OPTARG" ;;
    d) DELAY="$OPTARG" ;;
    c) COMPILER_VERSION="$OPTARG" ;;
    *) echo "Usage: $0 [-f json_file] [-d delay_seconds] [-c compiler_version]" >&2
       exit 1 ;;
  esac
done

# If no file specified, look in current directory
if [ -z "$JSON_FILE" ]; then
  JSON_FILE="run-latest.json"
fi

# Check if file exists
if [ ! -f "$JSON_FILE" ]; then
    echo "Error: $JSON_FILE not found!"
    exit 1
fi

echo "Using JSON file: $JSON_FILE"

# Try to detect compiler version from foundry.toml if not specified
if [ -z "$COMPILER_VERSION" ]; then
    # Look for foundry.toml in current or parent directories
    FOUNDRY_TOML=""
    for dir in "." ".." "../.." "../../.." "../../../.."; do
        if [ -f "$dir/foundry.toml" ]; then
            FOUNDRY_TOML="$dir/foundry.toml"
            break
        fi
    done
    
    if [ -n "$FOUNDRY_TOML" ]; then
        echo "Found foundry.toml at: $FOUNDRY_TOML"
        # Try to extract solc version from foundry.toml
        SOLC_VERSION=$(grep -E "solc\s*=\s*" "$FOUNDRY_TOML" | sed -E 's/.*solc\s*=\s*"([^"]+)".*/\1/')
        
        if [ -n "$SOLC_VERSION" ]; then
            COMPILER_VERSION="$SOLC_VERSION"
            echo "Detected compiler version from foundry.toml: $COMPILER_VERSION"
        fi
    fi
fi

if [ -n "$COMPILER_VERSION" ]; then
    COMPILER_FLAG="--compiler-version $COMPILER_VERSION"
    echo "Using compiler version: $COMPILER_VERSION"
else
    COMPILER_FLAG=""
    echo "No compiler version specified. Using default from foundry.toml"
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "The 'jq' command is not installed, which is needed to parse JSON."
    echo "Please install jq with one of these commands:"
    echo "  - Ubuntu/Debian: sudo apt-get install jq"
    echo "  - CentOS/RHEL: sudo yum install jq"
    echo "  - macOS: brew install jq"
    echo "  - Windows with Chocolatey: choco install jq"
    exit 1
fi

# Extract contract information from the JSON file using jq
echo "Extracting contract information from $JSON_FILE..."

# Get all CREATE and CREATE2 transactions
echo "Processing main contract deployments..."
contracts=$(jq -c '.transactions[] | select(.transactionType == "CREATE" or .transactionType == "CREATE2") | {contractName, contractAddress, arguments}' "$JSON_FILE")

# Process each contract
echo "$contracts" | while read -r contract; do
    name=$(echo "$contract" | jq -r '.contractName')
    address=$(echo "$contract" | jq -r '.contractAddress')
    
    echo "Verifying $name at $address..."
    
    # Check if arguments exist and are not null
    if [ "$(echo "$contract" | jq 'has("arguments") and .arguments != null and .arguments != []')" == "true" ]; then
        args_json=$(echo "$contract" | jq -c '.arguments')
        
        # Format arguments for display
        args_formatted=$(echo "$args_json" | jq -r '.[] | @sh' | tr '\n' ' ')
        echo "Contract has constructor arguments: $args_formatted"
        
        # Count arguments
        arg_count=$(echo "$args_json" | jq 'length')
        
        # Try to verify without guessing the constructor signature first
        echo "Attempting verification without specifying constructor arguments format..."
        if forge verify-contract "$address" "$name" --chain base $COMPILER_FLAG --watch; then
            echo "Verification successful!"
        else
            echo "Direct verification failed. Trying with constructor arguments..."
            
            # Try to guess constructor format based on argument count and patterns
            if [ "$arg_count" -eq 1 ] && [[ $(echo "$args_json" | jq -r '.[0]') == 0x* ]]; then
                # Single address argument
                echo "Trying with single address argument..."
                arg=$(echo "$args_json" | jq -r '.[0]')
                
                # Format verification command
                verify_cmd="forge verify-contract $address $name --chain base $COMPILER_FLAG --constructor-args \$(cast abi-encode \"constructor(address)\" \"$arg\")"
                echo "Executing: $verify_cmd"
                eval "$verify_cmd" --watch || echo "Verification failed for $name at $address"
                
            elif [ "$name" = "CollateralRegistry" ]; then
                # Special case for CollateralRegistry which has array arguments
                echo "Detected CollateralRegistry with array arguments..."
                
                # Extract the first argument (boldToken address)
                boldToken=$(echo "$args_json" | jq -r '.[0]')
                
                # For the collaterals array (second argument)
                # Try direct verification with a different approach for arrays
                echo "This contract requires special handling for array arguments."
                echo "Please verify manually with:"
                echo "forge verify-contract $address $name --chain base $COMPILER_FLAG"
                echo ""
                echo "If that fails, try reviewing run-latest.json and encode the constructor arguments manually:"
                echo "First argument (BOLD token): $boldToken"
                echo "Second argument (collateral tokens array): $(echo "$args_json" | jq -r '.[1]')"
                echo "Third argument (trove managers array): $(echo "$args_json" | jq -r '.[2]')"
                
                # Try a direct verification approach without specifying constructor args
                # This might work if the explorer can derive them from bytecode
                echo "Trying simplified verification approach..."
                forge verify-contract "$address" "$name" --chain base $COMPILER_FLAG --watch || {
                    echo "Verification failed. Please verify manually."
                }
                
            elif [ "$arg_count" -eq 6 ] && [ "$name" = "AddressesRegistry" ]; then
                # Special case for AddressesRegistry with 6 arguments (address, uint256, uint256, uint256, uint256, uint256)
                echo "Detected AddressesRegistry pattern with 6 arguments..."
                arg1=$(echo "$args_json" | jq -r '.[0]')  # address
                arg2=$(echo "$args_json" | jq -r '.[1]')  # uint256
                arg3=$(echo "$args_json" | jq -r '.[2]')  # uint256
                arg4=$(echo "$args_json" | jq -r '.[3]')  # uint256
                arg5=$(echo "$args_json" | jq -r '.[4]')  # uint256
                arg6=$(echo "$args_json" | jq -r '.[5]')  # uint256
                
                # Format verification command
                verify_cmd="forge verify-contract $address $name --chain base $COMPILER_FLAG --constructor-args \$(cast abi-encode \"constructor(address,uint256,uint256,uint256,uint256,uint256)\" \"$arg1\" \"$arg2\" \"$arg3\" \"$arg4\" \"$arg5\" \"$arg6\")"
                echo "Executing: $verify_cmd"
                eval "$verify_cmd" --watch || echo "Verification failed for $name at $address"
                
            else
                # Try a more general approach for complex arguments by automatically determining argument types
                echo "Complex constructor arguments detected. Attempting automatic type detection..."
                
                # Build constructor signature and arguments list
                CONSTRUCTOR_SIG="constructor("
                ARGS_LIST=""
                
                for i in $(seq 0 $(($arg_count - 1))); do
                    arg=$(echo "$args_json" | jq -r ".[$i]")
                    
                    # Add comma if not first argument
                    if [ $i -gt 0 ]; then
                        CONSTRUCTOR_SIG="${CONSTRUCTOR_SIG},"
                        ARGS_LIST="${ARGS_LIST} "
                    fi
                    
                    # Determine type based on value
                    if [[ $arg == 0x* ]] && [ ${#arg} -eq 42 ]; then
                        # Looks like an address
                        CONSTRUCTOR_SIG="${CONSTRUCTOR_SIG}address"
                    else
                        # Assume uint256 for numbers
                        CONSTRUCTOR_SIG="${CONSTRUCTOR_SIG}uint256"
                    fi
                    
                    # Add to args list
                    ARGS_LIST="${ARGS_LIST}\"$arg\""
                done
                
                CONSTRUCTOR_SIG="${CONSTRUCTOR_SIG})"
                
                echo "Trying with signature: $CONSTRUCTOR_SIG"
                
                # Format verification command
                verify_cmd="forge verify-contract $address $name --chain base $COMPILER_FLAG --constructor-args \$(cast abi-encode \"$CONSTRUCTOR_SIG\" $ARGS_LIST)"
                echo "Executing: $verify_cmd"
                eval "$verify_cmd" --watch || {
                    echo "Verification failed for $name at $address"
                    echo "Please verify manually with:"
                    echo "forge verify-contract $address $name --chain base $COMPILER_FLAG --constructor-args \$(cast abi-encode \"constructor(...)\")"
                }
            fi
        fi
    else
        # No constructor arguments
        echo "No constructor arguments"
        echo "Executing: forge verify-contract $address $name --chain base $COMPILER_FLAG --watch"
        
        # Execute the verification command
        forge verify-contract "$address" "$name" --chain base $COMPILER_FLAG --watch || echo "Verification failed for $name at $address"
    fi
    
    echo "Waiting $DELAY seconds before next verification to avoid rate limits..."
    sleep $DELAY
    echo "------------------------"
done

# Also process additionalContracts inside any transaction
echo "Looking for additional contracts inside transactions..."
additional_contracts=$(jq -c '.transactions[] | select(.additionalContracts != null) | .additionalContracts[] | select(.transactionType == "CREATE" or .transactionType == "CREATE2") | {address}' "$JSON_FILE")

if [ -n "$additional_contracts" ]; then
    echo "$additional_contracts" | while read -r contract; do
        address=$(echo "$contract" | jq -r '.address')
        
        echo "Found additional contract at $address"
        echo "Note: Additional contracts may need to be verified manually as they often don't have names in the deployment JSON."
        echo "Try: forge verify-contract $address ContractName --chain base $COMPILER_FLAG --watch"
        
        echo "Waiting $DELAY seconds before continuing..."
        sleep $DELAY
        echo "------------------------"
    done
fi

echo "Verification process complete!"