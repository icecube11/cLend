import { expect } from "chai"
import { ethers, deployments } from "hardhat"
import { CLending, IERC20, CoreDAO } from "../types"
import { blockNumber, getBigNumber, impersonate, advanceTimeAndBlock, latest } from "./utilities"
import { constants } from "../constants"
import { BigNumber } from "ethers"

let cLending: CLending
let coreDAO: CoreDAO
let coreDAOTreasury
let yearlyPercentInterest
let loanDefaultThresholdPercent
let coreCollaterability
let coreDaiCollaterability
let CORE: IERC20
let DAI: IERC20

describe("Lending", function () {
  beforeEach(async function () {
    const [deployer, account1] = await ethers.getSigners()
    await deployments.fixture()

    cLending = await ethers.getContract("CLending")
    coreDAO = await ethers.getContract("CoreDAO")
    coreDAOTreasury = await cLending.coreDAOTreasury()
    yearlyPercentInterest = await cLending.yearlyPercentInterest()
    loanDefaultThresholdPercent = await cLending.loanDefaultThresholdPercent()
    coreCollaterability = await cLending.collaterabilityOfToken(constants.CORE)
    coreDaiCollaterability = await cLending.loanDefaultThresholdPercent()

    CORE = await ethers.getContractAt<IERC20>("IERC20", constants.CORE)
    DAI = await ethers.getContractAt<IERC20>("IERC20", constants.DAI)

    // Give some CORE to account1
    await impersonate(constants.CORE_MULTISIG)
    const coreMultiSigSigner = await ethers.getSigner(constants.CORE_MULTISIG)
    await CORE.connect(coreMultiSigSigner).transfer(account1.address, getBigNumber(123))
    console.log("coreDAO balance in signer: " + (await coreDAO.balanceOf(coreMultiSigSigner.address)))
    // await coreDAO.connect(coreMultiSigSigner).transfer(account1.address, getBigNumber(123))

    // Fund the lending contract with DAI
    await DAI.connect(coreMultiSigSigner).transfer(cLending.address, await DAI.balanceOf(coreMultiSigSigner.address))
  })

  it("should let you put in CORE as collateral and get 5500 credit in each", async () => {
    const [deployer, account1] = await ethers.getSigners()

    const collateral = getBigNumber(20, 18)
    await CORE.connect(account1).approve(cLending.address, collateral)
    await cLending.connect(account1).addCollateral(constants.CORE, collateral)

    const credit = await cLending.userCollateralValue(account1.address)

    // Should be coreCollaterability core * collateral * 1e18
    expect(credit).to.equal(coreCollaterability.mul(collateral))
  })

  it("should let the guy borrow DAI for the amount", async () => {
    const [deployer, account1] = await ethers.getSigners()
    const collateral = getBigNumber(20, 18)
    await CORE.connect(account1).approve(cLending.address, collateral)
    await cLending.connect(account1).addCollateral(constants.CORE, collateral)

    const credit = await cLending.userCollateralValue(account1.address)

    // Should be coreCollaterability core * collateral * 1e18
    expect(credit).to.equal(coreCollaterability.mul(collateral))
    await cLending.connect(account1).borrow(credit)
    expect(await DAI.balanceOf(account1.address)).to.equal(credit)
  })

  it("should correctly add 20% a year interest", async () => {
    // Someone adds collateral and borrows 1000 DAI
    // Then he should have 10%/6months interest so less than 1% monthly from that meaning hsi debt at 110% would be 1100 DAI
  })

  it("should correctly not let people with more than 110% debt do anything except get liquidated", async () => {
    // Someone adds collateral and borrows 1000 DAI
    // Then wait 6months+1 day and it should not let them give it back cause they are in default
  })

  it("should lets people repay and get their debt lower", async () => {
    // Allows people to repay and get their debt lower
    const [deployer, account1] = await ethers.getSigners()
    const collateral = getBigNumber(20, 18) // in CORE
    const borrowAmount = getBigNumber(10000, 18) // in DAI
    const repayment = getBigNumber(1, 18) // in CORE, ie repaying 5500 in DAI
    const borrowedAmountAfterRepayment = getBigNumber(10, 18)
    await CORE.connect(account1).approve(cLending.address, collateral.add(repayment))
    // console.log("CORE balance before borrow: " + (await CORE.balanceOf(account1.address)))
    // console.log("DAI balance before borrow: " + (await DAI.balanceOf(account1.address)))
    // console.log("coreDAO balance before borrow: " + (await coreDAO.balanceOf(account1.address)))
    await cLending.connect(account1).addCollateralAndBorrow(constants.CORE, collateral, borrowAmount)
    // console.log("CORE balance after borrow: " + (await CORE.balanceOf(account1.address)))
    // console.log("DAI balance after borrow: " + (await DAI.balanceOf(account1.address)))
    // console.log("coreDAO balance after borrow: " + (await coreDAO.balanceOf(account1.address)))
    expect(await DAI.balanceOf(account1.address)).to.equal(borrowAmount)

    // console.log("Current block: " + (await latest()))
    // fast-forward the clock by 1 yr
    await advanceTimeAndBlock(86400 * 365)
    // console.log("New block: " + (await latest()))

    const totalDebtBeforeRepayment = await cLending.userTotalDebt(account1.address)
    console.log("outstanding loan amount with interest before repayment: " + totalDebtBeforeRepayment)
    const interests = await cLending.accruedInterest(account1.address)
    console.log("interests before repayment: " + interests)
    await cLending.connect(account1).repayLoan(constants.CORE, repayment)
    console.log("CORE balance after repayment: " + (await CORE.balanceOf(account1.address)))
    console.log("DAI balance after repayment: " + (await DAI.balanceOf(account1.address)))
    console.log("interests after repayment: " + (await cLending.accruedInterest(account1.address)))
    const totalDebtAfterRepayment = await cLending.userTotalDebt(account1.address)
    console.log("outstanding loan amount with interest after repayment: " + totalDebtAfterRepayment)
    const collaterabilityOfCore = await cLending.collaterabilityOfToken(constants.CORE)
    console.log("Collateral value per CORE token: " + collaterabilityOfCore)
    const newBorrowAmountWithoutInterest = borrowAmount.sub(repayment.mul(collaterabilityOfCore))
    console.log("expected new loan amount ignoring accured interest: " + newBorrowAmountWithoutInterest)

    // Borrow 10000 DAI, repay 5500 DAI: new borrowed amount is 4500 DAI when ignoring accured interests
    // therefore the new borrow amount taking accured interests into account should be >= 4500
    // (equal if interest rate is 0)
    expect(totalDebtAfterRepayment).gte(newBorrowAmountWithoutInterest)
  })

  it("should lets people provide too much to repay with any token, and it be calculated correctly based on the token collaterability", async () => {})

  it("should accrue interest correctly goes in DAI(based on collaterability) into the treasury, and is correctly removed from the user re-collaterisation/repayment", async () => {})

  it("should correctly reverts on trying to over borrow", async () => {})

  it("should let users reclaim all the collateral they gave", async () => {})

  it("should correctly doesnt let users reclaim collateral if they have any debt.", async () => {})

  it("The debtTime variable is correctly thought out and updates right in the right places making the user start over in his accural of interest after repayment", async () => {
    // This means after user repays their accrued interest (only can do it whole this is somethign we need to test as well)
  })

  it("Wrapping vouches works correctly and its correctly 1 DAI per voucher in the cLEnding", async () => {
    // correctly working meaning the token is taken out of the users wallet and sent to burn address, and they get the representative amount of coreDAO
    // uint256 public constant DAO_TOKENS_IN_LP1 = 2250;
    // uint256 public constant DAO_TOKENS_IN_LP2 = 9250e14;  <--- this means its cmLP i dont know if this is the right exponent, meanign 1cmLP should be worth 9250
    // uint256 public constant DAO_TOKENS_IN_LP3 = 45; <--- this is in DAI
    // Final numbers should just be lowered to first 5 from whatever decaf calculates for simplicity
  })
})
