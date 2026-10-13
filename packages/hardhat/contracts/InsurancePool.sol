// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract InsurancePool is AccessControl, ReentrancyGuard {
    ///////////////////
    /// Errors ///////
    ///////////////////
    error ZeroAmount();
    error InsufficientLiquidity(uint256 available, uint256 required);
    error PolicyAlreadyFunded(uint256 policyId);
    error PolicyNotActive(uint256 policyId);
    error TransferFailed();

    //////////////////////
    /// State Variables //
    //////////////////////
    bytes32 public constant INSURER_ROLE = keccak256("INSURER_ROLE");

    IERC20 public immutable usdc;

    // LP 份额（照 DEX 的写法）
    uint256 public totalLiquidity;
    mapping(address => uint256) public liquidity;

    // 保单准备金（NAV = A 需要）
    uint256 public totalLockedCoverage;   // 所有有效保单锁定的保额总和
    uint256 public totalRefundReserve;    // 所有有效保单的可退金额总和

    struct PolicyReserve {
        uint256 coverageAmount;
        uint256 refundableAmount;
        bool active;
    }
    mapping(uint256 => PolicyReserve) public policyReserves;

    ////////////////
    /// Events /////
    ////////////////
    event Deposited(address indexed provider, uint256 amount, uint256 shares);
    event Withdrawn(address indexed provider, uint256 shares, uint256 amount);
    event PolicyFunded(uint256 indexed policyId, uint256 coverageAmount, uint256 refundableAmount);
    event ClaimPaid(uint256 indexed policyId, address indexed beneficiary, uint256 amount);
    event RefundPaid(uint256 indexed policyId, address indexed beneficiary, uint256 amount);

    ///////////////////
    /// Constructor ///
    ///////////////////
    constructor(address usdc_, address admin) {
        usdc = IERC20(usdc_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    ///////////////////////
    /// NAV 计算（核心）///
    ///////////////////////

    /**
     * @notice 池子总资产 = USDC余额 - 退款准备金 - 锁定保额
     * @dev NAV = A（保守版）
     */
    function totalAssets() public view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance < totalRefundReserve + totalLockedCoverage) {
            return 0;
        }
        return balance - totalRefundReserve - totalLockedCoverage;
    }

    /**
     * @notice LP 可提取的流动性（用于提现限制）
     */
    function availableLiquidity() public view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance < totalRefundReserve + totalLockedCoverage) {
            return 0;
        }
        return balance - totalRefundReserve - totalLockedCoverage;
    }

    ///////////////////
    /// LP 存取 //////
    ///////////////////

    /**
     * @notice LP 存入 USDC，获得份额（照 DEX deposit 写法）
     */
    function deposit(uint256 amount, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (amount == 0) revert ZeroAmount();

        // 先记下"存款前的池子资产"（照 DEX 的 ethReserve 写法）
        uint256 assetsBefore = totalAssets();

        // 收 USDC
        bool ok = usdc.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        // 算份额（照 DEX：shares = amount * totalLiquidity / assetsBefore）
        if (totalLiquidity == 0 || assetsBefore == 0) {
            shares = amount;
        } else {
            shares = (amount * totalLiquidity) / assetsBefore;
        }

        liquidity[receiver] += shares;
        totalLiquidity += shares;

        emit Deposited(receiver, amount, shares);
        return shares;
    }

    /**
     * @notice LP 赎回份额，拿回 USDC（照 DEX withdraw 写法）
     */
    function withdraw(uint256 shares, address receiver)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (shares == 0) revert ZeroAmount();
        if (shares > liquidity[msg.sender]) {
            revert InsufficientLiquidity(liquidity[msg.sender], shares);
        }

        // 算能取回多少 USDC（照 DEX：amount = shares * assets / totalLiquidity）
        uint256 assets = totalAssets();
        amount = (shares * assets) / totalLiquidity;

        // 先更新状态，再转账（防重入）
        liquidity[msg.sender] -= shares;
        totalLiquidity -= shares;

        // 检查池子有没有足够"空闲"的钱
        uint256 balance = usdc.balanceOf(address(this));
        uint256 reserved = totalRefundReserve + totalLockedCoverage;
        if (balance < reserved + amount) {
            revert InsufficientLiquidity(balance - reserved, amount);
        }

        bool ok = usdc.transfer(receiver, amount);
        if (!ok) revert TransferFailed();

        emit Withdrawn(msg.sender, shares, amount);
        return amount;
    }

    ///////////////////////
    /// 保单资金操作 /////
    ///////////////////////

    /**
     * @notice 用户买保单：收保费，锁定保额和退款准备金
     * @dev 只允许 Insurance 合约调用
     */
    function fundPolicy(
        uint256 policyId,
        address payer,
        uint256 premium,
        uint256 coverageAmount,
        uint256 refundableAmount
    ) external onlyRole(INSURER_ROLE) nonReentrant {
        if (policyReserves[policyId].active) {
            revert PolicyAlreadyFunded(policyId);
        }
        if (premium == 0 || coverageAmount == 0) revert ZeroAmount();

        // 从 payer 收保费
        bool ok = usdc.transferFrom(payer, address(this), premium);
        if (!ok) revert TransferFailed();

        // 记录准备金
        policyReserves[policyId] = PolicyReserve({
            coverageAmount: coverageAmount,
            refundableAmount: refundableAmount,
            active: true
        });
        totalLockedCoverage += coverageAmount;
        totalRefundReserve += refundableAmount;

        emit PolicyFunded(policyId, coverageAmount, refundableAmount);
    }

    /**
     * @notice 出险赔付：从池子转保额给用户
     */
    function payClaim(uint256 policyId, address beneficiary)
        external
        onlyRole(INSURER_ROLE)
        nonReentrant
    {
        PolicyReserve memory r = policyReserves[policyId];
        if (!r.active) revert PolicyNotActive(policyId);

        // 更新准备金
        policyReserves[policyId].active = false;
        totalLockedCoverage -= r.coverageAmount;
        totalRefundReserve -= r.refundableAmount;

        // 转保额给用户
        bool ok = usdc.transfer(beneficiary, r.coverageAmount);
        if (!ok) revert TransferFailed();

        emit ClaimPaid(policyId, beneficiary, r.coverageAmount);
    }

    /**
     * @notice 未出险退款：把可退金额退给用户
     */
    function payExpiryRefund(uint256 policyId, address beneficiary)
        external
        onlyRole(INSURER_ROLE)
        nonReentrant
    {
        PolicyReserve memory r = policyReserves[policyId];
        if (!r.active) revert PolicyNotActive(policyId);

        // 更新准备金
        policyReserves[policyId].active = false;
        totalLockedCoverage -= r.coverageAmount;
        totalRefundReserve -= r.refundableAmount;

        // 退可退金额给用户
        bool ok = usdc.transfer(beneficiary, r.refundableAmount);
        if (!ok) revert TransferFailed();

        emit RefundPaid(policyId, beneficiary, r.refundableAmount);
    }
}