pragma solidity ^0.4.23;


import "../math/SafeMath.sol";
import "../tokens/ERC20.sol";
import "../tokens/ERC721.sol";
import "./TokenTransferProxy.sol";
import "./NFTokenTransferProxy.sol";
import "../tokens/ERC165implementation.sol";

/*
 * @dev based on: https://github.com/0xProject/contracts/blob/master/contracts/Exchange.sol
 */
contract Trader is ERC165implementation {

  using SafeMath for uint256;

  /*
   * @dev Enum of possible errors.
   */
  enum Errors {
    TRANSFER_ALREADY_PERFORMED, // Transfer has already beed performed.
    TRANSFER_CANCELLED, // Transfer was cancelled.
    INSUFFICIENT_BALANCE_OR_ALLOWANCE, // Insufficient balance or allowance for XCT transfer.
    NFTOKEN_NOT_ALLOWED // Is not the owner of NFToken.
  }

  /*
   * @dev contract addresses
   */
  address TOKEN_CONTRACT;
  address TOKEN_TRANSFER_PROXY_CONTRACT;
  address NFTOKEN_TRANSFER_PROXY_CONTRACT;

  /*
   * @dev Changes to state require at least 5000 gas.
   */
  uint16 constant public EXTERNAL_QUERY_GAS_LIMIT = 4999;

  /*
   * @dev Mapping of all canceled transfers.
   */
  mapping(bytes32 => bool) public transferCancelled;

  /*
   * @dev Mapping of all performed transfers.
   */
  mapping(bytes32 => bool) public transferPerformed;

  /*
   * @dev This event emmits when NFToken changes ownership.
   */
  event PerformTransfer(address indexed _from,
                        address _to,
                        bytes32 _nfTokenTransferClaim);

  /*
   * @dev This event emmits when NFToken transfer order is canceled.
   */
  event CancelTransfer(address indexed _from,
                       address _to,
                       bytes32 _nfTokenTransferClaim);


  /*
   * @dev Structure of data needed for a trade.
   */
  struct TransferData{
    address from;
    address to;
    address nfToken;
    uint256 id;
    address[] feeAddresses;
    uint256[] feeAmounts;
    uint256 seed;
    uint256 expirationTimestamp;
    bytes32 claim;
  }

  /*
   * @dev Sets XCT token address, Token proxy address and NFToken Proxy address.
   * @param _nfTokenToken Address pointing to XCT Token contract.
   * @param _tokenTransferProxy Address pointing to TokenTransferProxy contract.
   * @param _nfTokenTransferProxy Address pointing to none-fungible token transfer proxy contract.
   */
  constructor(address _xctToken,
              address _tokenTransferProxy,
              address _nfTokenTransferProxy)
    public
  {
    TOKEN_CONTRACT = _xctToken;
    TOKEN_TRANSFER_PROXY_CONTRACT = _tokenTransferProxy;
    NFTOKEN_TRANSFER_PROXY_CONTRACT = _nfTokenTransferProxy;
    supportedInterfaces[0x6b28faee] = true; // Trader
  }

  /*
   * @dev Get address of token used in exchange.
   */
  function getTokenAddress()
    external
    view
    returns (address)
  {
    return TOKEN_CONTRACT;
  }

  /*
   * @dev Get address of token transfer proxy used in exchange.
   */
  function getTokenTransferProxyAddress()
    external
    view
    returns (address)
  {
    return TOKEN_TRANSFER_PROXY_CONTRACT;
  }

  /*
   * @dev Get address of none-fundgible token transfer proxy used in exchange.
   */
  function getNFTokenTransferProxyAddress()
    external
    view
    returns (address)
  {
    return NFTOKEN_TRANSFER_PROXY_CONTRACT;
  }

  /*
   * @dev Performs the NFToken transfer.
   * @param _addresses Array of all addresses that go as following: 0 = Address of NFToken sender,
   * 1 = Address of NFToken reciever, 2 = Address of NFToken contract, 3 and more = Addresses of all
   * parties that need to get feeAmounts paid.
   * @param _uints Array of all uints that go as following: 0 = Id of NFToken, 1 = _seed Timestamp
   * that represents the salt, 2 = Timestamp of when the transfer claim expires,3 and more = Fee
   * amounts of all the _feeAddresses (length of both have to be the same).
   * @param _v ECDSA signature parameter v.
   * @param _r ECDSA signature parameters r.
   * @param _s ECDSA signature parameters s.
   * @param _throwIfNotTransferable Test the transfer before performing.
   */
  function performTransfer(address[] _addresses,
                           uint256[] _uints,
                           uint8 _v,
                           bytes32 _r,
                           bytes32 _s,
                           bool _throwIfNotTransferable)
    public
  {
    require(_addresses.length == _uints.length);

    TransferData memory transferData = TransferData({
      from: _addresses[0],
      to: _addresses[1],
      nfToken: _addresses[2],
      id: _uints[0],
      feeAddresses: _getAddressSubArray(_addresses, 3),
      feeAmounts: _getUintSubArray(_uints, 3),
      seed: _uints[1],
      expirationTimestamp: _uints[2],
      claim: getTransferDataClaim(
        _addresses,
        _uints
      )
    });

    require(transferData.to == msg.sender);
    require(transferData.from != transferData.to);
    require(transferData.expirationTimestamp >= now);

    require(isValidSignature(
      transferData.from,
      transferData.claim,
      _v,
      _r,
      _s
    ));

    require(!transferPerformed[transferData.claim], "Transfer already performed.");
    require(!transferCancelled[transferData.claim], "Transfer canceled.");

    if (_throwIfNotTransferable)
    {
      require(_canPayFee(transferData.to, transferData.feeAmounts), "Insufficient balance of allowance");
      require(_isAllowed(transferData.from, transferData.nfToken, transferData.id), "Token transfer not approved.");
    }

    transferPerformed[transferData.claim] = true;

    _transferViaNFTokenTransferProxy(transferData);

    _payfeeAmounts(transferData.feeAddresses, transferData.feeAmounts, transferData.to);

    emit PerformTransfer(
      transferData.from,
      transferData.to,
      transferData.claim
    );
  }

  /*
   * @dev Cancels NFToken transfer.
   * @param _addresses Array of all addresses that go as following: 0 = Address of NFToken sender,
   * 1 = Address of NFToken reciever, 2 = Address of NFToken contract, 3 and more = Addresses of all
   * parties that need to get feeAmounts paid.
   * @param _uints Array of all uints that go as following: 0 = Id of NFToken, 1 = _seed Timestamp
   * that represents the salt, 2 = Timestamp of when the transfer claim expires,3 and more = Fee
   * amounts of all the _feeAddresses (length of both have to be the same).
   */
  function cancelTransfer(address[] _addresses,
                          uint256[] _uints)
    public
  {
    require(msg.sender == _addresses[0]);

    bytes32 claim = getTransferDataClaim(
      _addresses,
      _uints
    );

    require(!transferPerformed[claim]);

    transferCancelled[claim] = true;

    emit CancelTransfer(
      _addresses[0],
      _addresses[1],
      claim
    );
  }

  /*
   * @dev Calculates keccak-256 hlaim of mint data from parameters.
   * @param _addresses Array of all addresses that go as following: 0 = Address of NFToken sender,
   * 1 = Address of NFToken reciever, 2 = Address of NFToken contract, 3 and more = Addresses of all
   * parties that need to get feeAmounts paid.
   * @param _uints Array of all uints that go as following: 0 = Id of NFToken, 1 = _seed Timestamp
   * that represents the salt, 2 = Timestamp of when the transfer claim expires,3 and more = Fee
   * amounts of all the _feeAddresses (length of both have to be the same).
   * @returns keccak-hash of transfer data.
   */
  function getTransferDataClaim(address[] _addresses,
                                uint256[] _uints)
    public
    constant
    returns (bytes32)
  {
    return keccak256(
      address(this),
      _addresses[0],
      _addresses[1],
      _addresses[2],
      _uints[0],
      _getAddressSubArray(_addresses, 3),
      _getUintSubArray(_uints, 3),
      _uints[1],
      _uints[2]
    );
  }

  /*
   * @dev Verifies if NFToken signature is valid.
   * @param _signer address of signer.
   * @param _claim Signed Keccak-256 hash.
   * @param _v ECDSA signature parameter v.
   * @param _r ECDSA signature parameters r.
   * @param _s ECDSA signature parameters s.
   * @return Validity of signature.
   */
  function isValidSignature(address _signer,
                            bytes32 _claim,
                            uint8 _v,
                            bytes32 _r,
                            bytes32 _s)
    public
    pure
    returns (bool)
  {
    return _signer == ecrecover(
      keccak256("\x19Ethereum Signed Message:\n32", _claim),
      _v,
      _r,
      _s
    );
  }

  /*
   * @dev Check is payer can pay the feeAmounts.
   * @param _to Address of the payer.
   * @param_ feeAmounts All the feeAmounts to be payed.
   * @return Confirmation if feeAmounts can be payed.
   */
  function _canPayFee(address _to,
                      uint256[] _feeAmounts)
    internal
    returns (bool)
  {
    uint256 feeAmountsum = 0;

    for(uint256 i; i < _feeAmounts.length; i++)
    {
      feeAmountsum = feeAmountsum.add(_feeAmounts[i]);
    }

    if(_getBalance(TOKEN_CONTRACT, _to) < feeAmountsum
      || _getAllowance(TOKEN_CONTRACT, _to) < feeAmountsum )
    {
      return false;
    }
    return true;
  }

  /*
   * @dev Transfers XCT tokens via TokenTransferProxy using transferFrom function.
   * @param _token Address of token to transferFrom.
   * @param _from Address transfering token.
   * @param _to Address receiving token.
   * @param _value Amount of token to transfer.
   * @return Success of token transfer.
   */
  function _transferViaTokenTransferProxy(address _token,
                                          address _from,
                                          address _to,
                                          uint _value)
    internal
    returns (bool)
  {
    return TokenTransferProxy(TOKEN_TRANSFER_PROXY_CONTRACT).transferFrom(
      _token,
      _from,
      _to,
      _value
    );
  }


  /*
   * @dev Transfers NFToken via NFTokenProxy using transfer function.
   * @param _nfToken Address of NFToken to transfer.
   * @param _from Address sending NFToken.
   * @param _to Address receiving NFToken.
   * @param _id Id of transfering NFToken.
   * @return Success of NFToken transfer.
   */
  function _transferViaNFTokenTransferProxy(TransferData _transferData)
    internal
  {
     NFTokenTransferProxy(NFTOKEN_TRANSFER_PROXY_CONTRACT)
      .transferFrom(_transferData.nfToken, _transferData.from, _transferData.to, _transferData.id);
  }

  /*
   * @dev Get token balance of an address.
   * The called token contract may attempt to change state, but will not be able to due to an added
   * gas limit. Gas is limited to prevent reentrancy.
   * @param _token Address of token.
   * @param _owner Address of owner.
   * @return Token balance of owner.
   */
  function _getBalance(address _token,
                       address _owner)
    internal
    returns (uint)
  {
    return ERC20(_token).balanceOf.gas(EXTERNAL_QUERY_GAS_LIMIT)(_owner);
  }

  /*
   * @dev Get allowance of token given to TokenTransferProxy by an address.
   * The called token contract may attempt to change state, but will not be able to due to an added
   * gas limit. Gas is limited to prevent reentrancy.
   * @param _token Address of token.
   * @param _owner Address of owner.
   * @return Allowance of token given to TokenTransferProxy by owner.
   */
  function _getAllowance(address _token,
                         address _owner)
    internal
    returns (uint)
  {
    return ERC20(_token).allowance.gas(EXTERNAL_QUERY_GAS_LIMIT)(
      _owner,
      TOKEN_TRANSFER_PROXY_CONTRACT
    );
  }

  /*
   * @dev Checks if we can transfer NFToken.
   * @param _from Address of NFToken sender.
   * @param _nfToken Address of NFToken contract.
   * @param _nfTokenId Id of NFToken (hashed certificate data that is transformed into uint256).
   + @return Permission if we can transfer NFToken.
   */
  function _isAllowed(address _from,
                      address _nfToken,
                      uint256 _nfTokenId)
    internal
    constant
    returns (bool)
  {
    if(ERC721(_nfToken).getApproved(_nfTokenId) == NFTOKEN_TRANSFER_PROXY_CONTRACT)
    {
      return true;
    }

    if(ERC721(_nfToken).isApprovedForAll(_from, NFTOKEN_TRANSFER_PROXY_CONTRACT))
    {
      return true;
    }

    return false;
  }

  /*
   * @dev Creates a sub array from address array.
   * @param _array Array from which we will make a sub array.
   * @param _index Index from which our sub array will be made.
   */
  function _getAddressSubArray(address[] _array, uint256 _index)
    internal
    pure
    returns (address[])
  {
    require(_array.length >= _index);
    address[] memory subArray = new address[](_array.length.sub(_index));
    uint256 j = 0;
    for(uint256 i = _index; i < _array.length; i++)
    {
      subArray[j] = _array[i];
      j++;
    }

    return subArray;
  }

  /*
   * @dev Creates a sub array from uint256 array.
   * @param _array Array from which we will make a sub array.
   * @param _index Index from which our sub array will be made.
   */
  function _getUintSubArray(uint256[] _array,
                            uint256 _index)
    internal
    pure
    returns (uint256[])
  {
    require(_array.length >= _index);
    uint256[] memory subArray = new uint256[](_array.length.sub(_index));
    uint256 j = 0;
    for(uint256 i = _index; i < _array.length; i++)
    {
      subArray[j] = _array[i];
      j++;
    }

    return subArray;
  }

  /**
   * @dev Helper function that pays all the feeAmounts.
   * @param _feeAddresses Addresses of all parties that need to get feeAmounts paid.
   * @param _feeAmounts Fee amounts of all the _feeAddresses (length of both have to be the same).
   * @param _to Address of the fee payer.
   * @return Success of payments.
   */
  function _payfeeAmounts(address[] _feeAddresses,
                          uint256[] _feeAmounts,
                          address _to)
    internal
  {
    for(uint256 i; i < _feeAddresses.length; i++)
    {
      if(_feeAddresses[i] != address(0) && _feeAmounts[i] > 0)
      {
        require(_transferViaTokenTransferProxy(
          TOKEN_CONTRACT,
          _to,
          _feeAddresses[i],
          _feeAmounts[i]
        ));
      }
    }
  }
}
