// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";

import "./interfaces/IBToken.sol";
import "./interfaces/IBounty.sol";
import "./interfaces/IStrategy.sol";
import "./utils/StakeFrozenMap.sol";
import "./utils/BonusPoolMap.sol";

contract Bounty is IBounty, Ownable, ReentrancyGuard {
    using SafeMath for uint;
    using SafeERC20 for IERC20;
    using StakeFrozenMap for StakeFrozenMap.UintToUintMap;
    using BonusPoolMap for BonusPoolMap.UintToPoolMap;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Info of each user.
    struct UserInfo {
        uint shares;     // How many want tokens the user has provided.
        uint sharesFrozen;

        uint bonusDebt;
        uint rewardDebt; // Reward debt. See explanation below.
        // We do some fancy math here. Basically, any point in time, the amount of BToken
        // entitled to a user but is pending to be distributed is:
        //
        //   amount = user.shares / sharesTotal * wantLockedTotal
        //   pending reward = (amount * pool.accPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws want tokens to a pool. Here's what happens:
        //   1. The pool's `accPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    struct PoolInfo {
        IERC20 want; // Address of the want token.
        IStrategy strat; // Strategy address that will auto compound want tokens

        uint allocPoint; // How many allocation points assigned to this pool. BToken to distribute per block.
        uint lastRewardBlock; // Last block number that BToken distribution occurs.
        uint accPerShare; // Accumulated BToken per share, times 1e12. See below.
        uint frozenPeriod;
    }

    BonusPoolMap.UintToPoolMap bonusPool;
    EnumerableSet.AddressSet whitelist;

    PoolInfo[] public poolInfo; // Info of each pool.
    mapping(uint => mapping(address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.
    mapping(uint => mapping(address => StakeFrozenMap.UintToUintMap)) frozenInfo;

    uint public constant blockOfTwoWeek = 403200; // 24 * 60 * 60 * 7 / 3
    uint public constant startBlock     = 3200000;
    uint public constant BMaxSupply     = 850000000e18;
    uint public constant BPerDay        = 3000000e18;

    address public BToken;
    address public development;

    uint public BPerBlock  = BPerDay.div(28800);
    uint public ownerARate = 1000;  // 10%

    uint public totalAllocPoint = 0; // Total allocation points. Must be the sum of all allocation points in all pools.
    uint public totalBonusPoint = 0;

    bool private canSetReduceRate = true;
    uint private reduceRate = 700; // 100 = 10%
    uint private lastPeriod = 0;

    // Events
    event Deposit(address indexed user, uint indexed pid, uint amount);
    event Withdraw(address indexed user, uint indexed pid, uint amount);
    event EmergencyWithdraw(address indexed user, uint indexed pid, uint amount);

    function poolLength() external view returns (uint) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // *** DO NOT add the same LP token more than once.
    // *** Rewards will be messed up if you do. (Only if want tokens are stored here.)
    function add(
        bool _withUpdate,
        bool _isOnlyStake,

        uint _allocPoint,
        uint _bonusPoint,
        uint _frozenPeriod,

        IERC20 _want,
        IStrategy _strat
    ) public override onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }

        uint lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);

        if (_isOnlyStake) {
            totalBonusPoint = totalBonusPoint.add(_bonusPoint);
            bonusPool.set(poolInfo.length, BonusPoolMap.Bonus({
                strat:           address(_strat),
                allocPoint:      _allocPoint,
                accPerShare:     0
            }));
        }

        poolInfo.push(
            PoolInfo({
                want:            _want,
                strat:           _strat,
                allocPoint:      _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accPerShare:     0,
                frozenPeriod:    _frozenPeriod
            })
        );

        whitelist.add(address(_strat));
    }

    // Update the given pool's BToken allocation point. Can only be called by the owner.
    function set(
        bool _withUpdate,
        uint _pid,
        uint _allocPoint,
        uint _bonusPoint,
        uint _frozenPeriod
    ) public override onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }

        PoolInfo storage pool = poolInfo[_pid];
        totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(
            _allocPoint
        );
        pool.allocPoint = _allocPoint;

        (bool isOnlyStake, BonusPoolMap.Bonus storage bonus) = bonusPool.tryGet(_pid);
        if (isOnlyStake) {
            totalBonusPoint = totalBonusPoint.sub(bonus.allocPoint).add(
                _bonusPoint
            );

            bonus.allocPoint = _bonusPoint;
            pool.frozenPeriod = _frozenPeriod;
        }
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint _from, uint _to)
        public
        view
        returns (uint)
    {
        if (IERC20(BToken).totalSupply() >= BMaxSupply) {
            return 0;
        }
        return _to.sub(_from);
    }

    function calcProfit(uint _pid) internal view returns (uint, uint) {
        PoolInfo storage pool = poolInfo[_pid];
        (bool isOnlyStake, BonusPoolMap.Bonus storage bonus) = bonusPool.tryGet(_pid);

        if (isOnlyStake) {
            return (pool.accPerShare, bonus.accPerShare);
        }

        return (pool.accPerShare, 0);
    }

    // View function to see pending BToken on frontend.
    function pending(uint _pid, address _user)
        external
        override
        view
        returns (uint)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        (uint reward1, uint reward2) = calcProfit(_pid);
        uint sharesTotal = pool.strat.sharesTotal();

        if (block.number > pool.lastRewardBlock && sharesTotal != 0) {
            uint multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint BReward =
                multiplier.mul(BPerBlock).mul(pool.allocPoint).div(
                    totalAllocPoint
                );

            reward1 = reward1.add(
                BReward.mul(1e12).div(sharesTotal)
            );
        }

        return user.shares.mul(reward1).div(1e12).sub(user.rewardDebt).add(
            user.shares.mul(reward2).div(1e12).sub(user.bonusDebt)
        );
    }

    // View function to see staked Want tokens on frontend.
    function stakedWantTokens(uint _pid, address _user)
        external
        view
        returns (uint, uint)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        StakeFrozenMap.UintToUintMap storage frozen = frozenInfo[_pid][_user];

        uint len    = frozen.length();
        uint locked = user.sharesFrozen;

        while (len-- > 0) {
            (uint k, uint val) = frozen.at(len);
            if (block.number >= k) {
                locked = locked.sub(val);
            }
        }

        uint sharesTotal     = pool.strat.sharesTotal();
        uint wantLockedTotal = pool.strat.wantLockedTotal();

        if (sharesTotal == 0) {
            return (0, 0);
        }

        uint factor = wantLockedTotal.mul(1e12).div(sharesTotal);
        return (user.shares.mul(factor).div(1e12), locked.mul(factor).div(1e12));
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint length = poolInfo.length;
        for (uint pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint _pid) public {
        if (block.number > startBlock) {
            uint period = block.number.sub(startBlock).div(blockOfTwoWeek);

            if (period <= 10) {
                uint elapse = period.sub(lastPeriod);
                if (elapse > 0) {
                    BPerBlock = BPerBlock.mul(reduceRate ** elapse).div(1000 ** elapse);
                    lastPeriod = period;
                }
            }
        }

        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        uint sharesTotal = pool.strat.sharesTotal();
        if (sharesTotal == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        if (multiplier <= 0) {
            return;
        }

        uint BReward =
            multiplier.mul(BPerBlock).mul(pool.allocPoint).div(
                totalAllocPoint
            );

        // Companion reward
        IBToken(BToken).mint(development, BReward.mul(ownerARate).div(10000));

        // Minted KingKong token
        IBToken(BToken).mint(address(this), BReward);

        pool.accPerShare = pool.accPerShare.add(
            BReward.mul(1e12).div(sharesTotal)
        );
        pool.lastRewardBlock = block.number;
    }

    function subFrozenStake(uint _pid, address _user) internal {
        UserInfo storage user = userInfo[_pid][_user];
        StakeFrozenMap.UintToUintMap storage frozen = frozenInfo[_pid][_user];

        uint len = frozen.length();
        while (len-- > 0) {
            (uint key, uint val) = frozen.at(len);

            if (block.number >= key) {
                user.sharesFrozen = user.sharesFrozen.sub(val);
                frozen.remove(key);
            }
        }
    }

    function addFrozenStake(uint _pid, address _user, uint _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        StakeFrozenMap.UintToUintMap storage frozen = frozenInfo[_pid][_user];

        uint frozenPeriod = pool.frozenPeriod.add(block.number);
        (bool exist, uint locked) = frozen.tryGet(frozenPeriod);

        if (exist) {
            frozen.set(frozenPeriod, locked.add(_amount));
        } else {
            frozen.set(frozenPeriod, _amount);
        }

        user.sharesFrozen = user.sharesFrozen.add(_amount);
    }

    // Want tokens moved from user -> AUTOFarm (BToken allocation) -> Strat (compounding)
    function deposit(uint _pid, uint _wantAmt) public override nonReentrant {
        updatePool(_pid);
        subFrozenStake(_pid, msg.sender);

        (uint reward1, uint reward2) = calcProfit(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.shares > 0) {
            uint pending_ =
                user.shares.mul(reward1).div(1e12).sub(user.rewardDebt).add(
                    user.shares.mul(reward2).div(1e12).sub(user.bonusDebt)
                );

            if (pending_ > 0) {
                safeBTransfer(msg.sender, pending_);
            }
        }
        if (_wantAmt > 0) {
            // 1. user -> pool
            pool.want.safeTransferFrom(address(msg.sender), address(this), _wantAmt);
            // 2. pool -> strategy
            pool.want.safeIncreaseAllowance(address(pool.strat), _wantAmt);

            // 3. increase user shares
            uint sharesAdded = pool.strat.deposit(msg.sender, _wantAmt);
            user.shares = user.shares.add(sharesAdded);

            // 4. update frozen period
            if (bonusPool.contains(_pid)) {
                addFrozenStake(_pid, msg.sender, sharesAdded);
            }
        }

        user.rewardDebt = user.shares.mul(reward1).div(1e12);
        user.bonusDebt = user.shares.mul(reward2).div(1e12);
        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint _pid, uint _wantAmt) public override nonReentrant {
        updatePool(_pid);
        subFrozenStake(_pid, msg.sender);

        (uint reward1, uint reward2) = calcProfit(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint sharesTotal     = pool.strat.sharesTotal();
        uint wantLockedTotal = pool.strat.wantLockedTotal();

        require(user.shares > 0, "user.shares is 0");
        require(sharesTotal > 0, "sharesTotal is 0");

        // Withdraw pending BToken
        uint pending_ = user.shares.mul(reward1).div(1e12).sub(user.rewardDebt).add(
                user.shares.mul(reward2).div(1e12).sub(user.bonusDebt)
            );
        if (pending_ > 0) {
            safeBTransfer(msg.sender, pending_);
        }

        // Withdraw want tokens
        uint amount =
            user.shares.sub(user.sharesFrozen).mul(wantLockedTotal).div(
                sharesTotal
            );

        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {
            uint sharesRemoved = pool.strat.withdraw(msg.sender, _wantAmt);

            if (sharesRemoved > user.shares) {
                user.shares = 0;
            } else {
                user.shares = user.shares.sub(sharesRemoved);
            }

            uint wantBal = pool.want.balanceOf(address(this));
            if (wantBal < _wantAmt) {
                _wantAmt = wantBal;
            }
            pool.want.safeTransfer(address(msg.sender), _wantAmt);
        }

        user.rewardDebt = user.shares.mul(reward1).div(1e12);
        user.bonusDebt = user.shares.mul(reward2).div(1e12);
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }

    function withdrawAll(uint _pid) public {
        withdraw(_pid, uint(-1));
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint _pid) public override {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint sharesTotal = pool.strat.sharesTotal();
        require(sharesTotal > 0, "sharesTotal is 0");

        uint wantLockedTotal = pool.strat.wantLockedTotal();
        uint amount =
            user.shares.sub(user.sharesFrozen).mul(wantLockedTotal).div(
                sharesTotal
            );

        if (amount > 0) {
            pool.strat.withdraw(msg.sender, amount);
            pool.want.safeTransfer(msg.sender, amount);

            user.shares = 0;
            user.rewardDebt = 0;
            user.bonusDebt = 0;

            emit EmergencyWithdraw(msg.sender, _pid, amount);
        }
    }

    // Safe BToken transfer function, just in case if rounding error causes pool to not have enough
    function safeBTransfer(address _to, uint _amount) internal {
        uint Bal = IERC20(BToken).balanceOf(address(this));
        if (_amount > Bal) {
            IERC20(BToken).transfer(_to, Bal);
        } else {
            IERC20(BToken).transfer(_to, _amount);
        }
    }

    function inCaseTokensGetStuck(address _token, uint _amount) public onlyOwner {
        require(_token != BToken, "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    function transmitBuyback(uint _amount) external override {
        require(whitelist.contains(msg.sender), "invalid strategy");

        uint length = bonusPool.length();
        for (uint i = 0; i < length; i++) {
            (, BonusPoolMap.Bonus storage pool) = bonusPool.at(i);

            uint BReward = _amount.mul(pool.allocPoint).div(totalBonusPoint);
            uint sharesTotal = IStrategy(pool.strat).sharesTotal();

            if (sharesTotal > 0) {
                pool.accPerShare = pool.accPerShare.add(
                    BReward.mul(1e12).div(sharesTotal)
                );
            }
        }
    }

    function setAddresses(address token_, address dev_) public onlyOwner {
        BToken = token_;
        development = dev_;
    }

    function setOwnerRate(uint a) public onlyOwner {
        ownerARate = a;
    }

    function setReduceRate(uint _rate) public onlyOwner {
        if (canSetReduceRate) {
            reduceRate = _rate;
        }
    }

    function renounceSetReduceRate() public onlyOwner {
        if (canSetReduceRate) {
            canSetReduceRate = false;
        }
    }

    function inspectUserInfo(uint pid_, address user_)
        public
        view
        returns (
            uint shares_,
            uint sharesFrozen_,
            uint bonusDebt_,
            uint rewardDebt_,
            uint[] memory k_,
            uint[] memory v_
        )
    {
        UserInfo storage user = userInfo[pid_][user_];
        StakeFrozenMap.UintToUintMap storage frozen = frozenInfo[pid_][user_];

        shares_       = user.shares;
        sharesFrozen_ = user.sharesFrozen;
        bonusDebt_    = user.bonusDebt;
        rewardDebt_   = user.rewardDebt;

        uint len = frozen.length();
        k_ = new uint[](len);
        v_ = new uint[](len);

        for (uint i = 0; i < len; i++) {
            (uint k, uint v) = frozen.at(i);

            k_[i] = k;
            v_[i] = v;
        }
    }
}
