pragma solidity 0.6.12;

import '@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol';
import '@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol';
import '@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol';
import '@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import './libs/IERC20.sol';

// import "@nomiclabs/buidler/console.sol";

// MasterChef is the master of Kiwi. He can make Kiwi and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once CAKE is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of CAKEs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accKiwiPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accKiwiPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. CAKEs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that CAKEs distribution occurs.
        uint256 accKiwiPerShare;  // Accumulated CAKEs per share, times 1e18. See below.
        uint16 depositFeeBP;      // Deposit fee in  basic points
        uint256 lpSupply;         // Total lp locked in pool
    }

    // The CAKE TOKEN!
    IERC20 public immutable kiwi;
    // CAKE tokens created per block.
    uint256 public kiwiPerBlock;
    // Deposit fee address
    address public feeAddress;

    mapping(address => bool) public poolExistence;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when CAKE mining starts.
    uint256 public immutable startBlock;
    bool public referralStatus = true;
    // Maximum deposit fee
    uint16 constant public maxDepositFee = 420;
    uint256 constant public MAX_EMISSION_RATE = 200000000000000;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event ReferralPayment(address indexed receiver, address giver, uint amount);
    event AddedPool(uint256 allocPoint, address lpToken, uint16 depositFeeBP);
    event AlteredPool(uint256 pid, uint256 allocPoint, uint16 depositFeeBP);
    event FeeAddressChanged(address newFeeAddress);
    event EmissionRateUpdated(uint newEmissionRate);
    event ReferralStatusToggled(bool newReferralStatus);
    

    constructor(
        IERC20 _kiwi,
        address _feeAddress,
        uint256 _kiwiPerBlock,
        uint256 _startBlock
    ) public {
        kiwi = _kiwi;
        kiwiPerBlock = _kiwiPerBlock;
        startBlock = _startBlock;
        feeAddress = _feeAddress;
    }

    modifier nonDuplicated (IBEP20 _lpToken) {
        require(poolExistence[address(_lpToken)] == false, "nonDuplicated: duplicated");
        _;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, bool _withUpdate) external onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= maxDepositFee, "deposit fees exceed maximum");
        _lpToken.balanceOf(address(this));

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[address(_lpToken)] = true;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accKiwiPerShare: 0,
            depositFeeBP: _depositFeeBP,
            lpSupply: 0
        }));

        emit AddedPool (_allocPoint, address(_lpToken), _depositFeeBP);
    }

    // Update the given pool's CAKE allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) external onlyOwner {
        require(_depositFeeBP <= maxDepositFee, "deposit fee exceed maximum");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }

        emit AlteredPool(_pid, _allocPoint, _depositFeeBP);
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from);
    }

    // View function to see pending CAKEs on frontend.
    function pendingKiwi(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accKiwiPerShare = pool.accKiwiPerShare;

        if (block.number > pool.lastRewardBlock && pool.lpSupply != 0 && totalAllocPoint > 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 kiwiReward = multiplier.mul(kiwiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accKiwiPerShare = accKiwiPerShare.add(kiwiReward.mul(1e18).div(pool.lpSupply));
        }
        return user.amount.mul(accKiwiPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }


    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        if (pool.lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 kiwiReward = multiplier.mul(kiwiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        // minting is itegrated in token on https://github.com/polykiwi-finance/polykiwi-token
        kiwi.mint(address(this), kiwiReward);
        pool.accKiwiPerShare = pool.accKiwiPerShare.add(kiwiReward.mul(1e18).div(pool.lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for CAKE allocation.
    function deposit(uint256 _pid, uint256 _amount, address referral) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accKiwiPerShare).div(1e18).sub(user.rewardDebt);
            if(pending > 0) {
                safeKiwiTransfer(msg.sender, pending);
                payReferral(referral, pending);
            }
        }
        if (_amount > 0) {
            uint256 balanceBefore = pool.lpToken.balanceOf(address(this));
            pool.lpToken.transferFrom(msg.sender, address(this), _amount);
            _amount = pool.lpToken.balanceOf(address(this)).sub(balanceBefore);

            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
                pool.lpSupply = pool.lpSupply.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
                pool.lpSupply = pool.lpSupply.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accKiwiPerShare).div(1e18);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount, address referral) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accKiwiPerShare).div(1e18).sub(user.rewardDebt);
        if(pending > 0) {
            safeKiwiTransfer(msg.sender, pending);

            payReferral(referral, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
            pool.lpSupply = pool.lpSupply.sub(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accKiwiPerShare).div(1e18);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function payReferral (address referral, uint amount) internal {
        if (referral != address(0) && referralStatus && referral != msg.sender) {
            amount = amount / 40; // 2.5%

            kiwi.mint(referral, amount);
            emit ReferralPayment(referral, msg.sender, amount);
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        pool.lpSupply = pool.lpSupply.sub(user.amount);

        user.amount = 0;
        user.rewardDebt = 0;

        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
    }

    // Safe kiwi transfer function, just in case if rounding error causes pool to not have enough CAKEs.
    function safeKiwiTransfer(address _to, uint256 _amount) internal {
        uint256 kiwiBal = kiwi.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > kiwiBal) {
            transferSuccess = kiwi.transfer(_to, kiwiBal);
        } else {
            transferSuccess = kiwi.transfer(_to, _amount);
        }
        require(transferSuccess, "safeKiwiTransfer: Transfer failed");
    }

    function setFeeAddress(address _feeAddress) external {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "!nonzero");
        feeAddress = _feeAddress;

        emit FeeAddressChanged(_feeAddress);
    }

    function updateEmissionRate(uint256 _kiwiPerBlock) external onlyOwner {
        require(_kiwiPerBlock <= MAX_EMISSION_RATE, "Emission rate too high");

        massUpdatePools();
        kiwiPerBlock = _kiwiPerBlock;

        emit EmissionRateUpdated(_kiwiPerBlock);
    }

    function toggleReferrals () external onlyOwner {
        referralStatus = !referralStatus;

        emit ReferralStatusToggled(referralStatus);
    }
}
