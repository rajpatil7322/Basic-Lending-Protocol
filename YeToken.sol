//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import "./Math.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

// Address provider 0xeb7A892BB04A8f836bDEeBbf60897A7Af1Bf5d7F

// ISwap router 0xE592427A0AEce92De3Edee1F18E0157C05861564

contract YeToken is ERC20Burnable,Ownable,Math {
    using SafeMath for uint256;

    uint256 public totalBorrowed;
    uint256 public totalReserve;
    uint256 public totalDeposit;
    uint256 public maxLTV = 4; // 1 = 20%
    uint256 public totalCollateral;
    uint256 public baseRate = 20000000000000000;
    uint256 public fixedAnnuBorrowRate = 300000000000000000;
     uint256 public ethTreasury;

    mapping(address => uint256) private usersCollateral;
    mapping(address => uint256) private usersBorrowed;
   

    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;
    IPool public immutable aave;
    ISwapRouter public immutable swapRouter;

    IERC20 public constant dai =IERC20(0xF14f9596430931E177469715c591513308244e8F);
    IERC20 public constant adai =IERC20(0xFAF6a49b4657D9c8dDa675c41cB9a05a94D3e9e9);

    IERC20 public constant weth =IERC20(0xD087ff96281dcf722AEa82aCA57E8545EA9e6C96);
    IERC20 public constant aweth =IERC20(0xAA02A95942Cb7d48Ac8ad8C3b5D65E546eC3Ecd3);

    AggregatorV3Interface internal constant priceFeed =AggregatorV3Interface(0x0715A7794a1dc8e42615F059dD6e406A6594651A);

    constructor(address _addressProvider,ISwapRouter _swapRouter)ERC20("Bond DAI", "bDAI") {
        ADDRESSES_PROVIDER = IPoolAddressesProvider(_addressProvider);
        aave = IPool(ADDRESSES_PROVIDER.getPool());
        swapRouter = _swapRouter;
    }

    function getLatestPrice() internal view returns(int256){
        (,int256 answer,,,)=priceFeed.latestRoundData();
        return answer*10**10;
    }

    function approveDai(uint256 amount) internal{
        dai.approve(address(aave),amount);
    }

    function sendDaiToAave(uint256 amount) internal {
        aave.supply(address(dai),amount,address(this),0);
    }

    function _withdrawDaiFromAave(uint256 _amount) internal {
        aave.withdraw(address(dai), _amount, msg.sender);
    }

    function unBondAsset(uint256 _amount)  external{
        require(_amount <= balanceOf(msg.sender), "Not enough bonds!");
        uint256 daiToReceive = mulExp(_amount, getExchangeRate());
        totalDeposit -= daiToReceive;
        burn(_amount);
        _withdrawDaiFromAave(daiToReceive);
    }

    function bondAsset(uint256 amount) external {
        dai.transferFrom(msg.sender,address(this),amount);
        approveDai(amount);
        totalDeposit += amount;
        sendDaiToAave(amount);
        uint256 bondsToMint=getExp(amount,getExchangeRate());
        _mint(msg.sender,bondsToMint);
    } 

    
    function getExchangeRate() public view returns (uint256) {
        if (totalSupply() == 0) {
            return 1000000000000000000;
        }
        uint256 cash = getCash();
        uint256 num = cash.add(totalBorrowed).add(totalReserve);
        return getExp(num, totalSupply());
    }

    function getCash() public view returns (uint256) {
        return totalDeposit.sub(totalBorrowed);
    }

    function aDaiBalance(address _address) public view returns(uint256){
        return adai.balanceOf(_address);
    }

    function _borrowLimit() public view returns (uint256) {
        uint256 amountLocked = usersCollateral[msg.sender];
        require(amountLocked > 0, "Collateral not found");
        uint256 amountBorrowed = usersBorrowed[msg.sender];
        uint256 wethPrice = uint256(getLatestPrice());
        uint256 amountLeft = mulExp(amountLocked, wethPrice).sub(
            amountBorrowed
        );
        return percentage(amountLeft, maxLTV);
    }

    function borrow(uint256 _amount) external {
        require(_amount <= _borrowLimit(), "Not enough collateral");
        usersBorrowed[msg.sender] += _amount;
        totalBorrowed += _amount;
        _withdrawDaiFromAave(_amount);
    }

      function addCollateral(uint256 amount) external {
        usersCollateral[msg.sender] += amount;
        totalCollateral += amount;
        weth.transferFrom(msg.sender,address(this),amount);
        approveWeth(amount);
        _sendWethToAave(amount);
    }

    function _sendWethToAave(uint256 amount) internal {
        aave.supply(address(weth),amount,address(this),0);
    }

    function approveWeth(uint256 amount) internal {
        weth.approve(address(aave),amount);
    }

    function _withdrawWethFromAave(uint256 amount) public {
        aave.withdraw(address(weth),amount,msg.sender);
    }

    function calculateBorrowFee(uint256 _amount)
        public
        view
        returns (uint256, uint256)
    {
        uint256 borrowRate = _borrowRate();
        uint256 fee = mulExp(_amount, borrowRate);
        uint256 paid = _amount.sub(fee);
        return (fee, paid);
    }

    function _interestMultiplier() public view returns (uint256) {
        uint256 uRatio = _utilizationRatio();
        uint256 num = fixedAnnuBorrowRate.sub(baseRate);
        return getExp(num, uRatio);
    }

    function _borrowRate() public view returns (uint256) {
        uint256 uRatio = _utilizationRatio();
        uint256 interestMul = _interestMultiplier();
        uint256 product = mulExp(uRatio, interestMul);
        return product.add(baseRate);
    }

        function _depositRate() public view returns (uint256) {
        uint256 uRatio = _utilizationRatio();
        uint256 bRate = _borrowRate();
        return mulExp(uRatio, bRate);
    }

    
    function _utilizationRatio() public view returns (uint256) {
        return getExp(totalBorrowed, totalDeposit);
    }

        function liquidation(address _user) external onlyOwner {
        uint256 wethPrice = uint256(getLatestPrice());
        uint256 collateral = usersCollateral[_user];
        uint256 borrowed = usersBorrowed[_user];
        uint256 collateralToUsd = mulExp(wethPrice, collateral);
        if (borrowed > percentage(collateralToUsd, maxLTV)) {
            _withdrawWethFromAave(collateral);
            uint256 amountDai = _convertEthToDai(collateral);
            totalReserve += amountDai;
            usersBorrowed[_user] = 0;
            usersCollateral[_user] = 0;
            totalCollateral -= collateral;
        }
    }

    function _convertEthToDai(uint256 amountIn) internal returns (uint256) {
         // msg.sender must approve this contract

        // Transfer the specified amount of DAI to this contract.
        TransferHelper.safeTransferFrom(address(dai), msg.sender, address(this), amountIn);

        // Approve the router to spend DAI.
        TransferHelper.safeApprove(address(dai), address(swapRouter), amountIn);

                // Naively set amountOutMinimum to 0. In production, use an oracle or other data source to choose a safer value for amountOutMinimum.
        // We also set the sqrtPriceLimitx96 to be 0 to ensure we swap our exact input amount.
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(dai),
                tokenOut: address(weth),
                fee: 3000,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        // The call to `exactInputSingle` executes the swap.
        uint256 amountOut = swapRouter.exactInputSingle(params);
        return amountOut;
    }

    function repay(uint256 _amount) external {
        require(usersBorrowed[msg.sender] > 0, "Doesnt have a debt to pay");
        dai.transferFrom(msg.sender, address(this), _amount);
        (uint256 fee, uint256 paid) = calculateBorrowFee(_amount);
        usersBorrowed[msg.sender] -= paid;
        totalBorrowed -= paid;
        totalReserve += fee;
        sendDaiToAave(_amount);
    }

    function removeCollateral(uint256 _amount) external {
        uint256 wethPrice = uint256(getLatestPrice());
        uint256 collateral = usersCollateral[msg.sender];
        require(collateral > 0, "Dont have any collateral");
        uint256 borrowed = usersBorrowed[msg.sender];
        uint256 amountLeft = mulExp(collateral, wethPrice).sub(borrowed);
        uint256 amountToRemove = mulExp(_amount, wethPrice);
        require(amountToRemove < amountLeft, "Not enough collateral to remove");
        usersCollateral[msg.sender] -= _amount;
        totalCollateral -= _amount;
        _withdrawWethFromAave(_amount);
        payable(address(this)).transfer(_amount);
    }

      function harvestRewards() external onlyOwner {
        uint256 aWethBalance = aweth.balanceOf(address(this));
        if (aWethBalance > totalCollateral) {
            uint256 rewards = aWethBalance.sub(totalCollateral);
            _withdrawWethFromAave(rewards);
            ethTreasury += rewards;
        }
    }

    receive() external payable {}

    fallback() external payable {}

}

