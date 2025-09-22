// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/IPTU.sol";

contract IPTUTest is Test {
    IPTU iptu;

    address owner = address(this);
    address prefeitura = address(0xBEEF);
    address contribuinte = address(0xCAFE);
    address atacante = address(0xDEAD);

    bytes32 public lancId;

    function setUp() public {
        iptu = new IPTU(prefeitura);
        vm.deal(contribuinte, 10 ether);
        vm.deal(atacante, 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function lancar() internal {
        vm.prank(prefeitura);
        lancId = iptu.lancarIPTU(
            "ABC123",
            contribuinte,
            2025,
            1 ether,
            4
        );
    }

    /*//////////////////////////////////////////////////////////////
                           TESTES BÁSICOS
    //////////////////////////////////////////////////////////////*/

    function testOwnerInicial() public {
        assertEq(iptu.owner(), owner);
    }

    function testPrefeituraInicial() public {
        assertEq(iptu.prefeitura(), prefeitura);
    }

    function testLancarIPTU() public {
        vm.prank(prefeitura);
        bytes32 id = iptu.lancarIPTU("XYZ", contribuinte, 2025, 1 ether, 2);
        (
            string memory inscricao,
            address contrib,
            uint256 ano,
            uint256 total,
            uint256 parcelas,
            ,
            ,
            ,
            bool ativo
        ) = iptu.getResumo(id);
        assertEq(inscricao, "XYZ");
        assertEq(contrib, contribuinte);
        assertEq(ano, 2025);
        assertEq(total, 1 ether);
        assertEq(parcelas, 2);
        assertTrue(ativo);
    }

    /*//////////////////////////////////////////////////////////////
                       PAGAMENTO DE PARCELAS
    //////////////////////////////////////////////////////////////*/

    function testPagarParcela() public {
        lancar();

        vm.startPrank(contribuinte);
        vm.expectEmit(true, true, true, true);
        emit IPTU.ParcelaPaga(lancId, 1, contribuinte, 0.25 ether, block.timestamp);
        iptu.pagarParcela{value: 0.25 ether}(lancId, 1);
        vm.stopPrank();

        assertTrue(iptu.parcelaEstaPaga(lancId, 1));
        (,,,,,,,uint256 valorPago,) = iptu.getResumo(lancId);
        assertEq(valorPago, 0.25 ether);
    }

    function testNaoAceitaValorErrado() public {
        lancar();
        vm.prank(contribuinte);
        vm.expectRevert(IPTU.WrongAmount.selector);
        iptu.pagarParcela{value: 0.1 ether}(lancId, 1);
    }

    function testParcelaInvalida() public {
        lancar();
        vm.prank(contribuinte);
        vm.expectRevert(IPTU.InvalidParcel.selector);
        iptu.pagarParcela{value: 0.25 ether}(lancId, 0);
    }

    function testParcelaJaPaga() public {
        lancar();
        vm.startPrank(contribuinte);
        iptu.pagarParcela{value: 0.25 ether}(lancId, 1);
        vm.expectRevert(IPTU.ParcelAlreadyPaid.selector);
        iptu.pagarParcela{value: 0.25 ether}(lancId, 1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       CONTROLE DE ACESSO
    //////////////////////////////////////////////////////////////*/

    function testSomentePrefeituraPodeLancar() public {
        vm.expectRevert(IPTU.NotPrefeitura.selector);
        iptu.lancarIPTU("ERR", contribuinte, 2025, 1 ether, 1);
    }

    function testSomenteOwnerPodeRepassar() public {
        lancar();
        vm.prank(contribuinte);
        iptu.pagarParcela{value: 0.25 ether}(lancId, 1);
        vm.prank(atacante);
        vm.expectRevert(IPTU.NotOwner.selector);
        iptu.repassarSaldo();
    }

    function testTransferOwnership() public {
        address novoOwner = address(0xAAAA);
        iptu.transferOwnership(novoOwner);
        assertEq(iptu.owner(), novoOwner);
    }

    /*//////////////////////////////////////////////////////////////
                        REENTRÂNCIA (NEGATIVO)
    //////////////////////////////////////////////////////////////*/

    function testNaoHaReentrancia() public {
        // contrato malicioso não consegue reentrar
        lancar();
        vm.prank(contribuinte);
        iptu.pagarParcela{value: 0.25 ether}(lancId, 1);

    }
}
