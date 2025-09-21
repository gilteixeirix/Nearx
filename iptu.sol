// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IPTU - Lançamento e Pagamento de IPTU com repasse à Prefeitura
/// @author ...
/// @notice Exemplo educativo. Faça auditoria antes de usar em produção.
contract IPTU {
    /*//////////////////////////////////////////////////////////////
                              ERROS
    //////////////////////////////////////////////////////////////*/
    error NotOwner();
    error NotPrefeitura();
    error InvalidParams();
    error AlreadyExists();
    error NotFound();
    error ParcelAlreadyPaid();
    error WrongAmount();
    error NotActive();
    error InvalidParcel();
    error WrongContribuinte();

    /*//////////////////////////////////////////////////////////////
                           CONTROLO DE ACESSO
    //////////////////////////////////////////////////////////////*/
    address public owner;
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    modifier onlyPrefeitura() {
        if (msg.sender != prefeitura) revert NotPrefeitura();
        _;
    }
    /*//////////////////////////////////////////////////////////////
                         PROTEÇÃO REENTRÂNCIA
    //////////////////////////////////////////////////////////////*/
    uint256 private _status;
    modifier nonReentrant() {
        require(_status != 2, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }

    /*//////////////////////////////////////////////////////////////
                            DADOS DO IPTU
    //////////////////////////////////////////////////////////////*/
    address public prefeitura; // carteira oficial que recebe os valores


    struct Lancamento {
        // Identificação básica
        string inscricao;         // inscrição municipal/cadastro do imóvel (texto curto)
        address contribuinte;     // responsável pelo pagamento
        uint256 ano;              // exercício (ex.: 2025)

        // Valores
        uint256 total;            // valor total do IPTU no ano (em wei)
        uint256 parcelas;         // número de parcelas
        uint256 valorParcela;     // valor fixo por parcela (simplificado)
        uint256 pagas;            // quantidade de parcelas já pagas
        uint256 valorPago;        // soma já paga

        // Estado
        bool ativo;               // permite bloquear um lançamento
        mapping(uint256 => bool) parcelaPaga; // parcela -> paga?
       
    }

    // id = keccak256(inscricao, contribuinte, ano) para localizar rapidamente
    mapping(bytes32 => Lancamento) private _lanc;

    /*//////////////////////////////////////////////////////////////
                                 EVENTOS
    //////////////////////////////////////////////////////////////*/
    event PrefeituraAtualizada(address indexed antiga, address indexed nova);
    event Lancado(bytes32 indexed id, string inscricao, address indexed contribuinte, uint256 ano, uint256 total, uint256 parcelas, uint256 valorParcela);
    event ParcelaPaga(bytes32 indexed id, uint256 indexed parcela, address indexed pagador, uint256 valor, uint256 timestamp);
    event RepasseEfetuado(address indexed para, uint256 valor);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUTOR
    //////////////////////////////////////////////////////////////*/
    constructor(address _prefeitura) {
        require(_prefeitura != address(0), "prefeitura zero");
        owner = msg.sender;
        prefeitura = _prefeitura;
        _status = 1;
    }

    /*//////////////////////////////////////////////////////////////
                       FUNCOES ADMINISTRATIVAS
    //////////////////////////////////////////////////////////////*/

    /// @notice Atualiza a carteira de recebimento da prefeitura
    function atualizarPrefeitura(address nova) external onlyOwner {
        require(nova != address(0), "prefeitura zero");
        emit PrefeituraAtualizada(prefeitura, nova);
        prefeitura = nova;
    }

    /// @notice Lança um IPTU para um contribuinte em um determinado ano
    /// @dev Por simplicidade, exige total divisível pelo número de parcelas
    function lancarIPTU(
        string calldata inscricao,
        address contribuinte,
        uint256 ano,
        uint256 total,
        uint256 parcelas
    ) external onlyPrefeitura returns (bytes32 id) {
        if (
            bytes(inscricao).length == 0 ||
            contribuinte == address(0) ||
            ano == 0 || total == 0 || parcelas == 0
        ) revert InvalidParams();

        id = _makeId(inscricao,  ano);

        // Para evitar colisões: se já existe e está ativo, não permitir
        if (_exists(id)) revert AlreadyExists();

        uint256 valorParcela = total / parcelas;
        if (valorParcela * parcelas != total) revert InvalidParams(); // requer divisão exata

        // Inicializa struct em storage
        Lancamento storage L = _lanc[id];
        L.inscricao = inscricao;
        L.contribuinte = contribuinte;
        L.ano = ano;
        L.total = total;
        L.parcelas = parcelas;
        L.valorParcela = valorParcela;
        L.ativo = true;
    
        emit Lancado(id, inscricao, contribuinte, ano, total, parcelas, valorParcela);
    }

    /// @notice Ativa/desativa um lançamento (por ex., em caso de cancelamento ou contestação)
    function setAtivo(bytes32 id, bool ativo) external onlyOwner {
        Lancamento storage L = _requireLanc(id);
        L.ativo = ativo;
    }

    /*//////////////////////////////////////////////////////////////
                      PAGAMENTO E REPASSE À PREFEITURA
    //////////////////////////////////////////////////////////////*/

    /// @notice Paga uma parcela específica do IPTU
    /// @param id Identificador do lançamento (retornado em `lancarIPTU`)
    /// @param parcela Número da parcela (1..N)
    function pagarParcela(bytes32 id, uint256 parcela)
        external
        payable
        nonReentrant
    {
        Lancamento storage L = _requireLanc(id);
        if (!L.ativo) revert NotActive();
        if (parcela == 0 || parcela > L.parcelas) revert InvalidParcel();
        if (L.parcelaPaga[parcela]) revert ParcelAlreadyPaid();
        if (msg.value != L.valorParcela) revert WrongAmount();
        if (msg.sender != L.contribuinte) revert WrongContribuinte();

        // Marca como paga
        L.parcelaPaga[parcela] = true;
        L.pagas += 1;
        L.valorPago += msg.value;

        emit ParcelaPaga(id, parcela, msg.sender, msg.value, block.timestamp);

        // Repasse imediato à prefeitura
        (bool ok, ) = payable(prefeitura).call{value: msg.value}("");
        require(ok, "Falha no repasse");
       
        emit RepasseEfetuado(prefeitura, msg.value);

    }

    /// @notice Função alternativa para repassar eventual saldo acumulado no contrato (caso algum pagamento tenha ficado retido por qualquer motivo)
    function repassarSaldo() external onlyOwner nonReentrant {
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok, ) = payable(prefeitura).call{value: bal}("");
            require(ok, "Falha no repasse");
            emit RepasseEfetuado(prefeitura, bal);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           CONSULTAS (VIEW)
    //////////////////////////////////////////////////////////////*/

    /// @notice Consulta resumo (sem o mapa de parcelas) para interfaces
    function getResumo(bytes32 id)
        external
        view
        returns (
            string memory inscricao,
            address contribuinte,
            uint256 ano,
            uint256 total,
            uint256 parcelas,
            uint256 valorParcela,
            uint256 pagas,
            uint256 valorPago,
            bool ativo
        )
    {
        Lancamento storage L = _requireLanc(id);
        return (
            L.inscricao,
            L.contribuinte,
            L.ano,
            L.total,
            L.parcelas,
            L.valorParcela,
            L.pagas,
            L.valorPago,
            L.ativo
        );
    }

    /// @notice Verifica se uma parcela específica já foi paga
    function parcelaEstaPaga(bytes32 id, uint256 parcela) external view returns (bool) {
        Lancamento storage L = _requireLanc(id);
        if (parcela == 0 || parcela > L.parcelas) revert InvalidParcel();
        return L.parcelaPaga[parcela];
    }

    /*//////////////////////////////////////////////////////////////
                             HELPERS INTERNOS
    //////////////////////////////////////////////////////////////*/
    function _makeId(string calldata inscricao,  uint256 ano) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(inscricao, ano));
    }

    function _exists(bytes32 id) internal view returns (bool) {
        // Como string default é vazia, checamos pelo contribuinte
        return _lanc[id].contribuinte != address(0);
    }

    function _requireLanc(bytes32 id) internal view returns (Lancamento storage) {
        Lancamento storage L = _lanc[id];
        if (L.contribuinte == address(0)) revert NotFound();
        return L;
    }

    /*//////////////////////////////////////////////////////////////
                       TRANSFERÊNCIA DE PROPRIEDADE
    //////////////////////////////////////////////////////////////*/
    /// @notice Transfere a titularidade do contrato (admin)
    function transferOwnership(address novoOwner) external onlyOwner {
        require(novoOwner != address(0), "owner zero");
        owner = novoOwner;
    }
}

