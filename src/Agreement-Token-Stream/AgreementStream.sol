//SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

/// @title AgreementStream
/// @author 0xPr0f
/// @notice Basic token streaming from a user to another user and vice versa simultaneously exchanging tokens based on an agreement

import {ISuperfluid, ISuperToken, ISuperApp, ISuperAgreement, SuperAppDefinitions} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {CFAv1Library} from "@superfluid-finance/ethereum-contracts/contracts/apps/CFAv1Library.sol";
import {IConstantFlowAgreementV1} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";
import {SuperAppBase} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBase.sol";

contract AgreementStream is SuperAppBase {
    using CFAv1Library for CFAv1Library.InitData;

    CFAv1Library.InitData public cfaV1Lib;
    bytes32 public constant CFA_ID =
        keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");

    constructor(ISuperfluid host) {
        assert(address(host) != address(0));
        cfaV1Lib = CFAv1Library.InitData(
            host,
            IConstantFlowAgreementV1(address(host.getAgreementClass(CFA_ID)))
        );

        uint256 configWord = SuperAppDefinitions.APP_LEVEL_FINAL |
            // change from 'before agreement stuff to after agreement
            SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
            SuperAppDefinitions.BEFORE_AGREEMENT_UPDATED_NOOP |
            SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP |
            SuperAppDefinitions.AFTER_AGREEMENT_CREATED_NOOP |
            SuperAppDefinitions.AFTER_AGREEMENT_UPDATED_NOOP;

        host.registerApp(configWord);
    }

    struct Agreements {
        address from;
        address to;
        uint256 amountFrom;
        uint256 amountTo;
        address tokenfromout;
        address tokentoout;
        int96 flowRatefrom;
        int96 flowRateto;
    }
    uint256 public NextID = 1;
    mapping(uint256 => Agreements) public IdtoAgreements;
    mapping(address => uint256[]) internal pendingAgreementsList;
    mapping(address => mapping(address => bool)) public approveAddress;
    //          from                to      amountFrom
    mapping(address => mapping(address => uint256)) public streamApprovalSetup;

    event createdNewRequest(
        address from,
        address to,
        uint256 amountFrom,
        uint256 amountTo,
        address tokenfromout,
        address tokentoout,
        int96 flowRatefrom,
        int96 flowRateto
    );

    event acceptNewRequest(
        address from,
        address to,
        uint256 amountFrom,
        uint256 amountTo,
        address tokenfromout,
        address tokentoout,
        int96 flowRate,
        int96 flowRateto
    );

    /// @dev require that the Id has info for approval
    modifier makeSureAgreementExist(uint256 _id) {
        require(_id != 0, "Out of range ID index");
        require(_id <= NextID, "Out of range ID index");
        require(
            IdtoAgreements[_id].from != address(0) ||
                IdtoAgreements[_id].to != address(0) ||
                IdtoAgreements[_id].amountTo > 0 ||
                IdtoAgreements[_id].amountFrom > 0
        );
        _;
    }
    /// @dev only the sender address can call
    modifier IdownerIsOG(uint256 _id) {
        require(
            IdtoAgreements[_id].from == msg.sender,
            "Not pending agreement"
        );
        _;
    }
    /// @dev only the reciever address or sender address can call
    modifier IsAgreedOn(uint256 _id) {
        require(
            IdtoAgreements[_id].from == msg.sender ||
                IdtoAgreements[_id].to == msg.sender,
            "No pending agreement"
        );
        _;
    }
    /// @dev only the reciever address or approvedAddress can call
    modifier recieverAcceptance(uint256 _id) {
        require(
            IdtoAgreements[_id].to == msg.sender ||
                approveAddress[IdtoAgreements[_id].to][msg.sender] == true,
            "Not pending agreement"
        );
        _;
    }

    /// @dev look for an element by value from an array and then pop it out when done
    function removeItemIndex(uint256 _element, uint256[] storage _array)
        private
        returns (bool)
    {
        for (uint256 i; i < _array.length; i++) {
            if (_array[i] == _element) {
                _array[i] = _array[_array.length - 1];
                _array.pop();
                return true;
            }
        }
        return false;
    }

    //1).
    // call an approve function here to approve the super token
    // cal authorise flow with operator on the supertoken
    /// @dev This is for userA to request 2 way simultanious stream from a userB
    /// params These are detials of the stream, some may not be strictly followed
    function requestAgreement(
        address to,
        uint256 amountFrom,
        uint256 amountTo,
        address tokenfromout,
        address tokentoout,
        int96 flowRatefrom,
        int96 flowRateto
    ) external {
        address from = msg.sender;
        require(ISuperToken(tokenfromout).balanceOf(from) > amountFrom);
        Agreements memory _agree = Agreements(
            from,
            to,
            amountFrom,
            amountTo,
            tokenfromout,
            tokentoout,
            flowRatefrom,
            flowRateto
        );
        IdtoAgreements[NextID] = _agree;
        pendingAgreementsList[to].push(NextID);
        unchecked {
            ++NextID;
        }
        emit createdNewRequest(
            from,
            to,
            amountFrom,
            amountTo,
            tokenfromout,
            tokentoout,
            flowRatefrom,
            flowRateto
        );
    }

    modifier approvalIsAlright(uint256 _id) {
        require(
            streamApprovalSetup[IdtoAgreements[_id].from][
                IdtoAgreements[_id].to
            ] == IdtoAgreements[_id].amountTo,
            "This has not be approved for the amount"
        );
        _;
    }

    //2).
    // call approve here to approve the super token
    // cal authorise flow with operator on the supertoken
    /// @dev This is for userB to accept the 2 way simultaneous stream from a userA
    /// @param _id ID of the stream for acceptance
    function acceptRequestAgreement(uint256 _id)
        external
        makeSureAgreementExist(_id)
        recieverAcceptance(_id)
    {
        /// IdtoAgreements[_id].amountTo => this is the amount that the approval will approve
        require(
            ISuperToken(IdtoAgreements[_id].tokentoout).balanceOf(
                IdtoAgreements[_id].to
            ) > IdtoAgreements[_id].amountTo
        );
        streamApprovalSetup[IdtoAgreements[_id].from][
            IdtoAgreements[_id].to
        ] = IdtoAgreements[_id].amountTo;
        bool isthere = removeItemIndex(_id, pendingAgreementsList[msg.sender]);
        require(isthere, "No valid index");
        emit acceptNewRequest(
            IdtoAgreements[_id].from,
            IdtoAgreements[_id].to,
            IdtoAgreements[_id].amountFrom,
            IdtoAgreements[_id].amountTo,
            IdtoAgreements[_id].tokenfromout,
            IdtoAgreements[_id].tokentoout,
            IdtoAgreements[_id].flowRatefrom,
            IdtoAgreements[_id].flowRateto
        );
    }

    /// @dev View all the Id sent to an address for approval
    function pendingAgreements(address from)
        external
        view
        returns (uint256[] memory idarray)
    {
        idarray = pendingAgreementsList[from];
    }

    /// @dev see the stream details for any Id
    /// @param _id ID of the stream to get the details
    function seeAgreementsById(uint256 _id)
        external
        view
        makeSureAgreementExist(_id)
        returns (Agreements memory)
    {
        return IdtoAgreements[_id];
    }

    /// @dev Approve an address to manage some fucntions
    /// @param _addressToApprove address to give approval power to
    /// @notice This may only work for some fucntions not all
    function approveAddressToManageStuffs(address _addressToApprove) external {
        require(
            _addressToApprove != address(0) || _addressToApprove != msg.sender
        );
        approveAddress[msg.sender][_addressToApprove] = !approveAddress[
            msg.sender
        ][_addressToApprove];
    }

    /// @dev Start the two way stream userA -> userB and UserB -> userA
    /// @param _id ID of the stream to activate
    /// @notice This will only work when the other party has accepted the stream
    function activateFlowbyFlowStream(uint256 _id)
        external
        makeSureAgreementExist(_id)
        IdownerIsOG(_id)
        approvalIsAlright(_id)
    {
        cfaV1Lib.cfa.createFlowByOperator(
            ISuperToken(IdtoAgreements[_id].tokenfromout),
            IdtoAgreements[_id].from,
            IdtoAgreements[_id].to,
            IdtoAgreements[_id].flowRatefrom,
            abi.encode(_id)
        );
        cfaV1Lib.cfa.createFlowByOperator(
            ISuperToken(IdtoAgreements[_id].tokentoout),
            IdtoAgreements[_id].to,
            IdtoAgreements[_id].from,
            IdtoAgreements[_id].flowRateto,
            abi.encode(_id)
        );
    }

    /// @dev Cancel and terminate the stream for the two parties with the streamId
    function cancelStreamsbyID(uint256 _id)
        external
        makeSureAgreementExist(_id)
        IsAgreedOn(_id)
    {
        _cancelStreamsbyID(_id);
    }

    /// @dev Cancel and terminate the stream for the two parties
    /// @param _id ID of the stream to terminate
    /// @notice This will cancel the stream for both parties
    function _cancelStreamsbyID(uint256 _id)
        private
        makeSureAgreementExist(_id)
        returns (bytes memory)
    {
        bytes memory ctx1 = cfaV1Lib.cfa.deleteFlowByOperator(
            ISuperToken(IdtoAgreements[_id].tokenfromout),
            IdtoAgreements[_id].from,
            IdtoAgreements[_id].to,
            abi.encode(_id)
        );

        bytes memory ctx2 = cfaV1Lib.cfa.deleteFlowByOperator(
            ISuperToken(IdtoAgreements[_id].tokentoout),
            IdtoAgreements[_id].to,
            IdtoAgreements[_id].from,
            abi.encode(_id)
        );
        streamApprovalSetup[IdtoAgreements[_id].from][
            IdtoAgreements[_id].to
        ] = 0;
        return abi.encode(ctx1, ctx2);
    }

    /// @dev SuperApp callback to be triggered when one party has terminated the stream which should give out the Id for both connection streams to be deleted and stopped
    /// @notice This might not work 100% well, due to maybe the misdecode of `_ctx`
    function afterAgreementTerminated(
        ISuperToken, /* _superToken*/
        address, /*_agreementClass*/
        bytes32, // _agreementId,
        bytes calldata, // _agreementData
        bytes calldata, // _cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        // According to the app basic law, we should never revert in a termination callback
        uint256 _id = abi.decode(_ctx, (uint256));
        newCtx = _cancelStreamsbyID(_id);
    }

    /// @dev get the flow details of a particular connection
    function getFlowInfo(
        address _checker,
        address _receiverFromChecker,
        ISuperToken _acceptedToken
    )
        external
        view
        returns (
            uint256 startTime,
            address checker,
            address receiver,
            int96 flowRate
        )
    {
        if (_checker != address(0) || _receiverFromChecker != address(0)) {
            (startTime, flowRate, , ) = cfaV1Lib.cfa.getFlow(
                _acceptedToken,
                _checker,
                _receiverFromChecker
            );
            receiver = _receiverFromChecker;
            checker = _checker;
        }
    }

    /// @dev make sure only the superfluid host calls the fucntion (callback)
    modifier onlyHost() {
        require(
            msg.sender == address(cfaV1Lib.host),
            "RedirectAll: support only one host"
        );
        _;
    }
}
