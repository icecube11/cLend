// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./CLendingLibrary.sol";
import "./types/CLendingTypes.sol";

/// This contract and its holdings are the property of CORE DAO
/// All unintened use is strictly prohibited.
contract CLending is OwnableUpgradeable {
    using CLendingLibrary for IERC20;

    IERC20 public constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 public constant CORE_TOKEN = IERC20(0x62359Ed7505Efc61FF1D56fEF82158CcaffA23D7);

    mapping(address => DebtorSummary) public debtorSummary;
    mapping(address => uint256) public collaterabilityOfToken;

    address public coreDAOTreasury;
    uint256 public yearlyPercentInterest;
    uint256 public loanDefaultThresholdPercent;

    /// @dev upfront storage allocation for further upgrades
    uint256[52] private _____gap;

    function initialize(
        address _coreDAOTreasury,
        IERC20 _daoToken,
        uint256 _yearlyPercentInterest,
        uint256 _loanDefaultThresholdPercent
    ) public initializer {
        __Ownable_init();

        coreDAOTreasury = _coreDAOTreasury;
        yearlyPercentInterest = _yearlyPercentInterest;
        loanDefaultThresholdPercent = _loanDefaultThresholdPercent;

        collaterabilityOfToken[address(CORE_TOKEN)] = 5500;
        collaterabilityOfToken[address(_daoToken)] = 1;
    }

    receive() external payable {
        revert("ETH is not accepted");
    }

    // It should be noted that this will change everything backwards in time meaning some people might be liquidated right away
    function changeLoanTerms(uint256 _yearlyPercentInterest, uint256 _loanDefaultThresholdPercent) public onlyOwner {
        yearlyPercentInterest = _yearlyPercentInterest;
        loanDefaultThresholdPercent = _loanDefaultThresholdPercent;
    }

    function editTokenCollaterability(address token, uint256 newCollaterability) public onlyOwner {
        collaterabilityOfToken[token] = newCollaterability;
    }

    // Repays the loan supplying collateral and not adding it
    function repayLoan(IERC20 token, uint256 amount) public {
        DebtorSummary storage userSummaryStorage = debtorSummary[msg.sender];
        (uint256 totalDebt, ) = liquidateDeliquent(msg.sender);
        require(totalDebt > 0, "No debt to repay");

        uint256 tokenCollateralAbility = collaterabilityOfToken[address(token)];
        require(tokenCollateralAbility > 0, "Not accepted for loan collateral");

        uint256 offeredCollateralValue = amount * tokenCollateralAbility;
        uint256 _accruedInterest = accruedInterest(msg.sender);
        require(offeredCollateralValue > _accruedInterest, "not enough to pay interest"); // Has to be done because we have to update debt time

        // Note that acured interest is never bigger than 10% of supplied collateral because of liquidateDeliquent call above
        if (offeredCollateralValue > totalDebt) {
            amount = totalDebt / tokenCollateralAbility;
            userSummaryStorage.amountDAIBorrowed = 0;
        } else {
            userSummaryStorage.amountDAIBorrowed =
                userSummaryStorage.amountDAIBorrowed -
                offeredCollateralValue +
                _accruedInterest;
            // Send the repayment amt
            updateDebtTime(userSummaryStorage);
        }

        token.safeTransferFrom(msg.sender, amount);

        // Send the accrued interest back to the DAO
        token.transfer(coreDAOTreasury, _accruedInterest / tokenCollateralAbility);
    }

    function _supplyCollateral(
        DebtorSummary storage userSummaryStorage,
        address user,
        IERC20 token,
        uint256 amount
    ) private {
        liquidateDeliquent(user);

        require(token != DAI, "DAI is not allowed as collateral");

        uint256 tokenCollateralAbility = collaterabilityOfToken[address(token)];
        require(tokenCollateralAbility != 0, "Not accepted as loan collateral");

        token.safeTransferFrom(user, amount);

        // We pay interest already accrued with the same mechanism as repay fn
        uint256 _accruedInterest = accruedInterest(user) / tokenCollateralAbility;

        require(_accruedInterest <= amount, "Not enough to repay interest");
        amount = amount - _accruedInterest;

        // We add collateral into the user struct
        _addCollateral(userSummaryStorage, token, amount);
    }

    function addCollateral(IERC20 token, uint256 amount) public {
        DebtorSummary storage userSummaryStorage = debtorSummary[msg.sender];
        _supplyCollateral(userSummaryStorage, msg.sender, token, amount);
        updateDebtTime(userSummaryStorage);
    }

    function addCollateralAndBorrow(
        IERC20 tokenCollateral,
        uint256 amountCollateral,
        uint256 amountBorrow
    ) public {
        DebtorSummary storage userSummaryStorage = debtorSummary[msg.sender];
        _supplyCollateral(userSummaryStorage, msg.sender, tokenCollateral, amountCollateral);
        _borrow(userSummaryStorage, msg.sender, amountBorrow);
    }

    function borrow(uint256 amount) public {
        DebtorSummary storage userSummaryStorage = debtorSummary[msg.sender];
        _borrow(userSummaryStorage, msg.sender, amount);
    }

    function _borrow(
        DebtorSummary storage userSummaryStorage,
        address user,
        uint256 amountBorrow
    ) private {
        uint256 totalDebt = userTotalDebt(user); // This is with interest
        uint256 totalCollateral = userCollateralValue(user);

        require(totalDebt <= totalCollateral && !isLiquidable(totalDebt, totalCollateral), "Over debted");

        uint256 userRemainingCollateral = totalCollateral - totalDebt;
        if (amountBorrow > userRemainingCollateral) {
            uint256 totalBorrowed = totalDebt + amountBorrow;
            require(totalBorrowed <= totalCollateral, "Too much borrowed");
            amountBorrow = totalCollateral - totalBorrowed;
        }

        editAmountBorrowed(userSummaryStorage, amountBorrow);
        DAI.transfer(user, amountBorrow);
    }

    function _addCollateral(
        DebtorSummary storage userSummaryStorage,
        IERC20 token,
        uint256 amount
    ) private {
        bool alreadySupplied;
        // Loops over all provided collateral, checks if its there and if it is edit it
        for (uint256 i = 0; i < userSummaryStorage.collateral.length; i++) {
            if (userSummaryStorage.collateral[i].collateralAddress == address(token)) {
                userSummaryStorage.collateral[i].suppliedCollateral =
                    userSummaryStorage.collateral[i].suppliedCollateral +
                    amount;
                alreadySupplied = true;
                break;
            }
        }

        // If it has not been already supplied we push it on
        if (!alreadySupplied) {
            userSummaryStorage.collateral.push(
                Collateral({collateralAddress: address(token), suppliedCollateral: amount})
            );
        }
    }

    function isLiquidable(uint256 totalDebt, uint256 totalCollateral) private view returns (bool) {
        return (totalDebt * loanDefaultThresholdPercent) / 100 > totalCollateral;
    }

    // Liquidates people in default
    function liquidateDeliquent(address user) private returns (uint256 totalDebt, uint256 totalCollateral) {
        totalDebt = userTotalDebt(user); // This is with interest
        totalCollateral = userCollateralValue(user);

        if (isLiquidable(totalDebt, totalCollateral)) {
            // user is in default, wipe their debt and collateral
            delete debtorSummary[user];
            return (0, 0);
        }
    }

    function reclaimAllCollateral() public {
        (uint256 totalDebt, uint256 totalCollateral) = liquidateDeliquent(msg.sender);

        require(totalCollateral > 0, "No collateral to reclaim or collateral liquidated");
        require(totalDebt == 0, "Still in debt");

        for (uint256 i = 0; i < debtorSummary[msg.sender].collateral.length; i++) {
            uint256 supplied = debtorSummary[msg.sender].collateral[i].suppliedCollateral;
            IERC20(debtorSummary[msg.sender].collateral[i].collateralAddress).transfer(msg.sender, supplied);
        }

        // User doesnt have collateral anymore and paid off debt, bye
        delete debtorSummary[msg.sender];
    }

    function userCollateralValue(address user) public view returns (uint256 collateral) {
        Collateral[] memory userCollateralTokens = debtorSummary[user].collateral;

        for (uint256 i = 0; i < userCollateralTokens.length; i++) {
            Collateral memory currentToken = userCollateralTokens[i];
            uint256 tokenDebit = collaterabilityOfToken[currentToken.collateralAddress] *
                currentToken.suppliedCollateral;
            collateral = collateral + tokenDebit;
        }
    }

    function userTotalDebt(address user) public view returns (uint256) {
        return accruedInterest(user) + debtorSummary[user].amountDAIBorrowed;
    }

    function accruedInterest(address user) public view returns (uint256) {
        DebtorSummary memory userSummaryMemory = debtorSummary[user];
        uint256 timeSinceLastLoan = block.timestamp - userSummaryMemory.timeLastBorrow;
        return (userSummaryMemory.amountDAIBorrowed * yearlyPercentInterest / 100 * timeSinceLastLoan) / 365 days; // 365days * 100
    }

    function editAmountBorrowed(DebtorSummary storage userSummaryStorage, uint256 addToBorrowed) private {
        userSummaryStorage.amountDAIBorrowed = userSummaryStorage.amountDAIBorrowed + addToBorrowed;
        updateDebtTime(userSummaryStorage);
    }

    function updateDebtTime(DebtorSummary storage userSummaryStorage) private {
        userSummaryStorage.timeLastBorrow = block.timestamp;
    }
}
