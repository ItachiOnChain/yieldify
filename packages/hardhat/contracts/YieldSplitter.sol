// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./PrincipalToken.sol";
import "./YieldToken.sol";
import "./WrappedKDA.sol";

/**
 * @title YieldSplitter
 * @dev Main contract that splits wKDA into PT-wKDA and YT-wKDA tokens
 * @notice This contract handles deposit, split, redeem, and yield distribution
 */
contract YieldSplitter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    
    // Token contracts
    WrappedKDA public immutable wrappedKDA;
    PrincipalToken public immutable principalToken;
    YieldToken public immutable yieldToken;
    
    // Maturity timestamp
    uint256 public immutable maturity;
    
    // Protocol state
    bool public isExpired;
    uint256 public totalDeposited;
    uint256 public totalYieldDistributed;
    
    // User deposits tracking
    mapping(address => uint256) public userDeposits;
    mapping(address => uint256) public userPTBalance;
    mapping(address => uint256) public userYTBalance;
    
    // Yield distribution
    uint256 public lastYieldDistribution;
    uint256 public yieldDistributionInterval = 1 days;
    
    // Events
    event Deposit(address indexed user, uint256 amount);
    event Split(address indexed user, uint256 wkdaAmount, uint256 ptAmount, uint256 ytAmount);
    event Redeem(address indexed user, uint256 ptAmount, uint256 ytAmount, uint256 wkdaAmount);
    event YieldDistributed(uint256 amount, uint256 timestamp);
    event MaturityReached();
    
    modifier onlyBeforeMaturity() {
        require(block.timestamp < maturity, "Contract has matured");
        _;
    }
    
    modifier onlyAfterMaturity() {
        require(block.timestamp >= maturity, "Contract not yet matured");
        _;
    }
    
    constructor(
        address payable _wrappedKDA,
        uint256 _maturityDuration // Duration in seconds (e.g., 365 days)
    ) {
        wrappedKDA = WrappedKDA(_wrappedKDA);
        maturity = block.timestamp + _maturityDuration;
        
        // Deploy PT and YT tokens
        principalToken = new PrincipalToken(
            "Principal Token wKDA",
            "PT-wKDA",
            _wrappedKDA,
            maturity
        );
        
        yieldToken = new YieldToken(
            "Yield Token wKDA", 
            "YT-wKDA",
            _wrappedKDA,
            maturity
        );
        
        // Set this contract as the yield splitter for both tokens
        principalToken.setYieldSplitter(address(this));
        yieldToken.setYieldSplitter(address(this));
        
        // Cross-reference the tokens
        principalToken.setYieldToken(address(yieldToken));
        yieldToken.setPrincipalToken(address(principalToken));
        
        lastYieldDistribution = block.timestamp;
    }
    
    /**
     * @notice Deposit wKDA and split into PT and YT tokens
     * @param amount Amount of wKDA to deposit and split
     */
    function depositAndSplit(uint256 amount) external nonReentrant onlyBeforeMaturity {
        require(amount > 0, "Amount must be greater than 0");
        
        // Transfer wKDA from user
        wrappedKDA.transferFrom(msg.sender, address(this), amount);
        
        // Update tracking
        userDeposits[msg.sender] += amount;
        userPTBalance[msg.sender] += amount;
        userYTBalance[msg.sender] += amount;
        totalDeposited += amount;
        
        // Mint PT and YT tokens (1:1 ratio)
        principalToken.mint(msg.sender, amount);
        yieldToken.mint(msg.sender, amount);
        
        emit Deposit(msg.sender, amount);
        emit Split(msg.sender, amount, amount, amount);
    }
    
    /**
     * @notice Redeem PT and YT tokens back to wKDA before maturity
     * @param amount Amount of PT+YT tokens to redeem
     */
    function redeemBeforeMaturity(uint256 amount) external nonReentrant onlyBeforeMaturity {
        require(amount > 0, "Amount must be greater than 0");
        require(principalToken.balanceOf(msg.sender) >= amount, "Insufficient PT balance");
        require(yieldToken.balanceOf(msg.sender) >= amount, "Insufficient YT balance");
        
        // Burn PT and YT tokens
        principalToken.burn(msg.sender, amount);
        yieldToken.burn(msg.sender, amount);
        
        // Update tracking
        userPTBalance[msg.sender] -= amount;
        userYTBalance[msg.sender] -= amount;
        totalDeposited -= amount;
        
        // Transfer wKDA back to user
        wrappedKDA.transfer(msg.sender, amount);
        
        emit Redeem(msg.sender, amount, amount, amount);
    }
    
    /**
     * @notice Redeem PT tokens for wKDA after maturity
     * @param amount Amount of PT tokens to redeem
     */
    function redeemPTAfterMaturity(uint256 amount) external nonReentrant onlyAfterMaturity {
        require(amount > 0, "Amount must be greater than 0");
        require(principalToken.balanceOf(msg.sender) >= amount, "Insufficient PT balance");
        
        // Burn PT tokens
        principalToken.burn(msg.sender, amount);
        
        // Update tracking
        userPTBalance[msg.sender] -= amount;
        
        // Transfer wKDA back to user (1:1 redemption)
        wrappedKDA.transfer(msg.sender, amount);
        
        emit Redeem(msg.sender, amount, 0, amount);
    }
    
    /**
     * @notice Claim yield from YT tokens
     * @return yieldAmount Amount of yield claimed
     */
    function claimYield() external nonReentrant returns (uint256 yieldAmount) {
        yieldAmount = yieldToken.getClaimableYield(msg.sender);
        require(yieldAmount > 0, "No yield to claim");
        
        // Trigger yield claim in YT contract
        yieldToken.claimYield();
        
        // Transfer yield to user (in wKDA)
        // Note: In a real implementation, this would come from actual yield generation
        // For MVP, we'll mint new wKDA as mock yield
        _distributeYieldToUser(msg.sender, yieldAmount);
        
        totalYieldDistributed += yieldAmount;
    }
    
    /**
     * @notice Distribute yield to all YT holders (can be called by anyone)
     */
    function distributeYield() external nonReentrant {
        require(
            block.timestamp >= lastYieldDistribution + yieldDistributionInterval,
            "Too early for yield distribution"
        );
        
        // Mock yield generation - in reality this would come from staking/lending
        uint256 yieldToDistribute = _calculateMockYield();
        
        if (yieldToDistribute > 0) {
            lastYieldDistribution = block.timestamp;
            totalYieldDistributed += yieldToDistribute;
            emit YieldDistributed(yieldToDistribute, block.timestamp);
        }
    }
    
    /**
     * @notice Mark contract as expired after maturity
     */
    function markAsExpired() external onlyAfterMaturity {
        if (!isExpired) {
            isExpired = true;
            principalToken.markAsExpired();
            yieldToken.markAsExpired();
            emit MaturityReached();
        }
    }
    
    /**
     * @notice Get user's current position
     * @param user Address to check
     * @return ptBalance PT token balance
     * @return ytBalance YT token balance  
     * @return claimableYield Amount of yield claimable
     */
    function getUserPosition(address user) external view returns (
        uint256 ptBalance,
        uint256 ytBalance,
        uint256 claimableYield
    ) {
        ptBalance = principalToken.balanceOf(user);
        ytBalance = yieldToken.balanceOf(user);
        claimableYield = yieldToken.getClaimableYield(user);
    }
    
    /**
     * @notice Get contract statistics
     * @return totalDeposited_ Total wKDA deposited
     * @return totalYieldDistributed_ Total yield distributed
     * @return maturity_ Maturity timestamp
     * @return isExpired_ Whether contract has expired
     */
    function getContractStats() external view returns (
        uint256 totalDeposited_,
        uint256 totalYieldDistributed_,
        uint256 maturity_,
        bool isExpired_
    ) {
        totalDeposited_ = totalDeposited;
        totalYieldDistributed_ = totalYieldDistributed;
        maturity_ = maturity;
        isExpired_ = isExpired;
    }
    
    /**
     * @notice Calculate mock yield for demonstration
     * @return yieldAmount Mock yield amount
     */
    function _calculateMockYield() internal view returns (uint256 yieldAmount) {
        if (totalDeposited == 0) return 0;
        
        // Mock 5% APY distributed daily
        // yieldAmount = (totalDeposited * 5 * 1 day) / (100 * 365 days)
        yieldAmount = (totalDeposited * 5) / (100 * 365);
        
        // Cap at available balance
        uint256 availableBalance = wrappedKDA.balanceOf(address(this));
        if (yieldAmount > availableBalance / 10) { // Don't use more than 10% of reserves
            yieldAmount = availableBalance / 10;
        }
    }
    
    /**
     * @notice Distribute yield to a specific user (internal)
     * @param user User to distribute yield to
     * @param amount Amount of yield to distribute
     */
    function _distributeYieldToUser(address user, uint256 amount) internal {
        // In a real implementation, this would come from actual yield sources
        // For MVP demo, we'll use contract's wKDA balance or mint new tokens
        uint256 contractBalance = wrappedKDA.balanceOf(address(this));
        
        if (contractBalance >= amount) {
            wrappedKDA.transfer(user, amount);
        } else {
            // Fallback: mint new wKDA as mock yield (deposit KDA to wKDA contract)
            // This is just for demo purposes
            wrappedKDA.deposit{value: amount}();
            wrappedKDA.transfer(user, amount);
        }
    }
    
    /**
     * @notice Emergency function to recover stuck tokens (only owner)
     */
    function emergencyRecover(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
    
    /**
     * @notice Set yield distribution interval (only owner)
     */
    function setYieldDistributionInterval(uint256 _interval) external onlyOwner {
        yieldDistributionInterval = _interval;
    }
    
    // Allow contract to receive KDA for mock yield generation
    receive() external payable {}
}
