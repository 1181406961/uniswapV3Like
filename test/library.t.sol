pragma solidity ^0.8.14;
import "forge-std/Test.sol";
/// library的this和sender都是指向合约
library A {
    function getThis() public view {
        console.log("A addree is ");
        console.log(address(this));
    }
    function getSender() public view{
        console.log("A sender is ");
        console.log(msg.sender);
    }
}

contract B {
    function testA() public view {
        A.getThis();
        console.log("B address is ");
        console.log(address(this));
    }
    function testSender() public view{
        A.getSender();
        console.log("B sender is ");
        console.log(msg.sender);
    }
}
