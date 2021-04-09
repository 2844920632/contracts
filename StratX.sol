// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "./interfaces/IFarmPool.sol";
import "./interfaces/IDexRouter.sol";
import "./interfaces/IBounty.sol";
import "./interfaces/IWETH.sol";

contract StratX is Ownable, ReentrancyGuard, Pausable {
    // Maximize yields in HecoPool

    using SafeMath for uint;
    using SafeERC20 for IERC20;

    bool public onlyGov = true;
    bool public isErc20Token; // isn't LP token.
    bool public isAutoComp; // this vault is purely for staking. eg. liquidity pool vault.

    IFarmPool public farmPool; // address of farm, eg, Heco, Bsc etc.
    uint public pid; // pid of pool in farmPool
    IDexRouter public router; // uniswap, mdex, pancakeswap etc

    address public desire; // deposit token
    address public token0; // lp token0
    address public token1; // lp token1
    address public earned;

    address public BFarmPool;
    address public BToken;
    address public governor; // timelock contract
    address public retrieve; // vaults of buyback BToken

    uint public lastEarnBlock = 0;
    uint public sharesTotal = 0;
    uint public wantLockedTotal = 0;

    address public constant WHT = 0x5545153CCFcA01fbd7Dd11C0b23ba694D9509A6F;

    uint public buyBackRate = 200;
    uint public bonusRate = 400;
    uint public constant buyBackRateMax = 10000; // 100 = 1%
    uint public constant buyBackRateUL = 800;

    uint public entranceFeeFactor = 9995; // < 0.05% entrance fee - goes to pool + prevents front-running
    uint public constant entranceFeeFactorMax = 10000;
    uint public constant entranceFeeFactorLL = 9950; // 0.5% is the max entrance fee settable. LL = lowerlimit

    address[] public desireToEarnedPath;
    address[] public earnedToDesirePath;
    address[] public earnedToBTokenPath;
    address[] public earnedToToken0Path;
    address[] public earnedToToken1Path;
    address[] public token0ToEarnedPath;
    address[] public token1ToEarnedPath;

    constructor(
        address _retrieve,
        address _BFarmPool,
        address _BToken,

        bool _isErc20Token,
        bool _isAutoComp,

        IFarmPool _farmPool,
        uint _pid,

        address _desire,
        address _token0,
        address _token1,
        address _earned,

        IDexRouter _router
    ) public {
        governor = msg.sender;
        retrieve = _retrieve;

        BFarmPool = _BFarmPool;
        BToken    = _BToken;

        isErc20Token = _isErc20Token;
        isAutoComp   = _isAutoComp;

        desire = _desire;
        earned = _earned;

        if (!isErc20Token) {
            token0 = _token0;
            token1 = _token1;
        }

        if (isAutoComp) {
            farmPool = _farmPool;
            pid = _pid;
            router = _router;

            // convert entrance fee to earned iff desire isn't LP token
            desireToEarnedPath = [desire, WHT, earned];
            if (WHT == desire) {
                desireToEarnedPath = [WHT, earned];
            }

            earnedToDesirePath = [earned, WHT, desire];
            if (WHT == earned) {
                earnedToDesirePath = [WHT, desire];
            }

            earnedToBTokenPath = [earned, WHT, BToken];
            if (WHT == earned) {
                earnedToBTokenPath = [WHT, BToken];
            }

            earnedToToken0Path = [earned, WHT, token0];
            if (WHT == token0) {
                earnedToToken0Path = [earned, WHT];
            }

            earnedToToken1Path = [earned, WHT, token1];
            if (WHT == token1) {
                earnedToToken1Path = [earned, WHT];
            }

            token0ToEarnedPath = [token0, WHT, earned];
            if (WHT == token0) {
                token0ToEarnedPath = [WHT, earned];
            }

            token1ToEarnedPath = [token1, WHT, earned];
            if (WHT == token1) {
                token1ToEarnedPath = [WHT, earned];
            }
        }

        transferOwnership(BFarmPool);
    }

    // Receives new deposits from user
    function deposit(address _userAddress, uint _wantAmt)
        public
        onlyOwner
        whenNotPaused
        returns (uint)
    {
        // Shh
        _userAddress;
        uint sharesAdded = _wantAmt;

        if (isAutoComp) {
            IERC20(desire).safeTransferFrom(address(msg.sender), address(this), _wantAmt);

            if (wantLockedTotal > 0) {
                uint entranceAmt = _wantAmt.mul(entranceFeeFactor).div(entranceFeeFactorMax);
                uint entranceFee = _wantAmt.sub(entranceAmt);

                sharesAdded = entranceAmt.mul(sharesTotal).div(wantLockedTotal);

                IERC20(desire).safeIncreaseAllowance(
                    address(router),
                    entranceFee
                );

                if (isErc20Token) {
                    router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                        entranceFee,
                        0,
                        desireToEarnedPath,
                        address(this),
                        now + 60
                    );
                } else {
                    // 1. LP entrance fee breakdown token0 & token1
                    router.removeLiquidity(
                        token0,
                        token1,
                        entranceFee,
                        0,
                        0,
                        address(this),
                        now + 60
                    );

                    // 2. token0 & token1 convert to earned
                    convertDustToEarned();
                }

                uint fee = IERC20(earned).balanceOf(address(this));
                IERC20(earned).safeIncreaseAllowance(address(router), fee);
                buyBack(fee);
            }

            _farm();
        } else {
            wantLockedTotal = wantLockedTotal.add(sharesAdded);
        }

        sharesTotal = sharesTotal.add(sharesAdded);
        return sharesAdded;
    }

    function farm() public nonReentrant {
        _farm();
    }

    function _farm() internal {
        uint wantAmt = IERC20(desire).balanceOf(address(this));
        wantLockedTotal = wantLockedTotal.add(wantAmt);

        IERC20(desire).safeIncreaseAllowance(
            address(farmPool),
            wantAmt
        );

        farmPool.deposit(pid, wantAmt);
    }

    function withdraw(address _userAddress, uint _wantAmt)
        public
        onlyOwner
        nonReentrant
        returns (uint)
    {
        // Shh
        _userAddress;
        require(_wantAmt > 0, "_wantAmt <= 0");

        if (isAutoComp) {
            farmPool.withdraw(pid, _wantAmt);
            uint wantAmt = IERC20(desire).balanceOf(address(this));

            if (_wantAmt > wantAmt) {
                _wantAmt = wantAmt;
            }
        }

        if (wantLockedTotal < _wantAmt) {
            _wantAmt = wantLockedTotal;
        }

        uint sharesRemoved = _wantAmt.mul(sharesTotal).div(wantLockedTotal);
        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);
        wantLockedTotal = wantLockedTotal.sub(_wantAmt);

        if (isAutoComp) {
            IERC20(desire).safeTransfer(BFarmPool, _wantAmt);
        }
        return sharesRemoved;
    }

    // 1. Harvest farm tokens
    // 2. Converts farm tokens into desire tokens
    // 3. Deposits desire tokens
    function earn() public whenNotPaused {
        require(isAutoComp, "!isAutoComp");
        if (onlyGov) {
            require(msg.sender == governor, "Not authorised");
        }

        // Harvest farm tokens
        farmPool.withdraw(pid, 0);

        // Converts farm tokens into desire tokens
        uint earnedAmt = IERC20(earned).balanceOf(address(this));
        uint buybacked = earnedAmt.mul(buyBackRate).div(buyBackRateMax);

        IERC20(earned).safeIncreaseAllowance(
            address(router),
            earnedAmt
        );

        // Buy back BToken
        if (buybacked > 0) {
            buyBack(buybacked);
            earnedAmt = earnedAmt.sub(buybacked);
        }

        if (isErc20Token) {
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                earnedAmt,
                0,
                earnedToDesirePath,
                address(this),
                now + 60
            );

            lastEarnBlock = block.number;
            _farm();
            return;
        }

        if (earned != token0) {
            // Swap half earned to token0
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                earnedAmt.div(2),
                0,
                earnedToToken0Path,
                address(this),
                now + 60
            );
        }

        if (earned != token1) {
            // Swap half earned to token1
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                earnedAmt.div(2),
                0,
                earnedToToken1Path,
                address(this),
                now + 60
            );
        }

        // Get desire tokens, ie. add liquidity
        uint token0Amt = IERC20(token0).balanceOf(address(this));
        uint token1Amt = IERC20(token1).balanceOf(address(this));

        if (token0Amt > 0 && token1Amt > 0) {
            IERC20(token0).safeIncreaseAllowance(
                address(router),
                token0Amt
            );
            IERC20(token1).safeIncreaseAllowance(
                address(router),
                token1Amt
            );

            router.addLiquidity(
                token0,
                token1,
                token0Amt,
                token1Amt,
                0,
                0,
                address(this),
                now + 60
            );
        }

        lastEarnBlock = block.number;
        _farm();
    }

    function buyBack(uint _amount) internal {
        // bonus of frozen pool
        uint bonus = _amount.mul(bonusRate).div(buyBackRateMax);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            bonus,
            0,
            earnedToBTokenPath,
            BFarmPool,
            now + 60
        );
        IBounty(BFarmPool).transmitBuyback(bonus);

        // remaining distribute to retrieve address
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amount.sub(bonus),
            0,
            earnedToBTokenPath,
            retrieve,
            now + 60
        );
    }

    function convertDustToEarned() public whenNotPaused {
        require(isAutoComp, "!isAutoComp");
        require(!isErc20Token, "isErc20Token");

        // Converts dust tokens into earned tokens, which will be reinvested on the next earn().

        // Converts token0 dust (if any) to earned tokens
        uint token0Amt = IERC20(token0).balanceOf(address(this));
        if (token0 != earned && token0Amt > 0) {
            IERC20(token0).safeIncreaseAllowance(
                address(router),
                token0Amt
            );

            // Swap all dust tokens to earned tokens
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                token0Amt,
                0,
                token0ToEarnedPath,
                address(this),
                now + 60
            );
        }

        // Converts token1 dust (if any) to earned tokens
        uint token1Amt = IERC20(token1).balanceOf(address(this));
        if (token1 != earned && token1Amt > 0) {
            IERC20(token1).safeIncreaseAllowance(
                address(router),
                token1Amt
            );

            // Swap all dust tokens to earned tokens
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                token1Amt,
                0,
                token1ToEarnedPath,
                address(this),
                now + 60
            );
        }
    }

    function pause() public {
        require(msg.sender == governor, "Not authorised");
        _pause();
    }

    function unpause() external {
        require(msg.sender == governor, "Not authorised");
        _unpause();
    }

    function setEntranceFeeFactor(uint _entranceFeeFactor) public {
        require(msg.sender == governor, "Not authorised");
        require(_entranceFeeFactor > entranceFeeFactorLL, "!safe - too low");
        require(_entranceFeeFactor <= entranceFeeFactorMax, "!safe - too high");
        entranceFeeFactor = _entranceFeeFactor;
    }

    function setbuyBackRate(uint _buyBackRate) public {
        require(msg.sender == governor, "Not authorised");
        require(buyBackRate <= buyBackRateUL, "too high");
        buyBackRate = _buyBackRate;
    }

    function setBonusRate(uint _bonusRate) public {
        require(msg.sender == governor, "Not authorised");
        bonusRate = _bonusRate;
    }

    function setGov(address _governor) public {
        require(msg.sender == governor, "!gov");
        governor = _governor;
    }

    function setOnlyGov(bool _onlyGov) public {
        require(msg.sender == governor, "!gov");
        onlyGov = _onlyGov;
    }

    function inCaseTokensGetStuck(
        address _token,
        uint _amount,
        address _to
    ) public {
        require(msg.sender == governor, "!gov");
        require(_token != earned, "!safe");
        require(_token != desire, "!safe");
        IERC20(_token).safeTransfer(_to, _amount);
    }
}
