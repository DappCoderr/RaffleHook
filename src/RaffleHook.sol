// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import {LPFeeLibrary} from "v4-periphery/lib/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

contract RaffleHook is BaseHook {

    using CurrencyLibrary for Currency;

    // Raffle configuration
    uint256 public swapCount;
    uint256 public constant FEE_PER_SWAP = 0.005 ether; // 0.005 ETH per swap
    uint256 public immutable SWAPS_PER_ROUND;
    
    // Raffle state
    address[] public swappers;
    uint256 public rewardPool;
    uint256 public lastRequestId;
    
    // Chainlink VRF
    VRFCoordinatorV2Interface public immutable COORDINATOR;
    uint64 public immutable SUBSCRIPTION_ID;
    bytes32 public immutable KEY_HASH;
    uint32 public constant CALLBACK_GAS_LIMIT = 200000;
    
    // Events
    event RaffleStarted(uint256 requestId, uint256 reward);
    event WinnerSelected(address winner, uint256 amount);
    event FeeCollected(address swapper, uint256 amount);

    error OnlyCoordinatorCanFulfill();
    error InvalidPool();
    error TransferFailed();
    error InvalidHookData();


    constructor(IPoolManager _manager, uint256 entranceFee, uint256 interval, address vrf_coordinator, bytes32 gasLane, uint64 subscriptionId, uint32 callbackGasLimit) BaseHook(_manager) VRFConsumerBaseV2(vrf_coordinator){
        i_entranceFee = entranceFee;
        i_interval = interval;
        s_raffleStartingTime = block.timestamp;
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrf_coordinator);
        i_gasLane = gasLane;
        i_subscriptionId = subscriptionId;
        s_raffleState = RaffleState.OPEN;
        i_callbackGasLimit = callbackGasLimit;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external pure override returns (bytes4, int128) {
        // attachec to ETH-TOKEN pool, otherwise ignore
        if (!key.currency0.isAddressZero()) return (this.afterSwap.selector, 0);
        // Check user is buying TOKEN with ETH
        if (!swapParams.zeroForOne) return (this.afterSwap.selector, 0);
        // how much user is spending in ETH
        uint256 ethSpendByUser = uint256(int256(-delta.amount0()));
        // Check if the swap amount is sufficient to cover the fee
        if (ethSpendByUser > FEE_PER_SWAP) return (this.afterSwap.selector, 0);
        // Check if the pool is valid
        if (hookData.length == 0) revert InvalidHookData();


        // Collect fee
        rewardPool += FEE_PER_SWAP;
        swappers.push(sender);
        swapCount++;
        
        emit FeeCollected(sender, FEE_PER_SWAP);

        // Start raffle when threshold reached
        if (swapCount >= SWAPS_PER_ROUND) {
            lastRequestId = COORDINATOR.requestRandomWords(
                KEY_HASH,
                SUBSCRIPTION_ID,
                3, // Confirmations
                CALLBACK_GAS_LIMIT,
                1  // Number of words
            );
            emit RaffleStarted(lastRequestId, rewardPool);
        }

        return (this.afterSwap.selector, 0);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        if (requestId != lastRequestId) return;
        
        // Select winner
        uint256 winnerIndex = randomWords[0] % swappers.length;
        address winner = swappers[winnerIndex];
        
        // Transfer reward
        (bool success, ) = winner.call{value: rewardPool}("");
        if (!success) revert TransferFailed();
        
        emit WinnerSelected(winner, rewardPool);
        
        // Reset state
        delete swappers;
        swapCount = 0;
        rewardPool = 0;
    }

    // Required for receiving ETH rewards
    receive() external payable {}
}
