// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IStrategy.sol";

interface IBounty {
    function add(
        bool _withUpdate,
        bool _isOnlyStake,

        uint _allocPoint,
        uint _bonusPoint,
        uint _frozenPeriod,

        IERC20 _want,
        IStrategy _strat
    ) external;

    function set(
        bool _withUpdate,
        uint _pid,
        uint _allocPoint,
        uint _bonusPoint,
        uint _frozenPeriod
    ) external;

    function pending(uint256 pid, address user) external view returns (uint256);

    function deposit(uint256 pid, uint256 amount) external;

    function withdraw(uint256 pid, uint256 amount) external;

    function emergencyWithdraw(uint256 pid) external;

    function transmitBuyback(uint _amount) external ;
}
