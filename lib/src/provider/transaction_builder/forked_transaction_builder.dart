import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';

/// A transaction builder specifically designed for the Bitcoin Cash (BCH) and Bitcoin SV (BSV) networks.
/// Implements [BasedBitcoinTransacationBuilder] interface for creating and validating transactions.
///
/// The [ForkedTransactionBuilder] constructs transactions with specified outputs, fees, and additional parameters
/// such as UTXOs, memo, enableRBF (Replace-By-Fee), and more.
///
/// Parameters:
/// - [outPuts]: List of Bitcoin outputs to be included in the transaction.
/// - [fee]: Transaction fee (BigInt) for processing the transaction.
/// - [network]: The target Bitcoin network (Bitcoin Cash or Bitcoin SV).
/// - [utxosInfo]: List of UtxoWithAddress objects providing information about Unspent Transaction Outputs (UTXOs).
/// - [memo]: Optional memo or additional information associated with the transaction.
/// - [enableRBF]: Flag indicating whether Replace-By-Fee (RBF) is enabled. Default is false.
/// - [isFakeTransaction]: Flag indicating whether the transaction is a fake/mock transaction. Default is false.
/// - [inputOrdering]: Ordering preference for transaction inputs. Default is BIP-69.
/// - [outputOrdering]: Ordering preference for transaction outputs. Default is BIP-69.
///
/// Note: The constructor automatically validates the builder by calling the [_validateBuilder] method.
class ForkedTransactionBuilder implements BasedBitcoinTransacationBuilder {
  final List<BitcoinBaseOutput> outPuts;
  final BigInt fee;
  final BasedUtxoNetwork network;
  final List<UtxoWithAddress> utxosInfo;
  final String? memo;
  final bool enableRBF;
  final bool isFakeTransaction;
  final BitcoinOrdering inputOrdering;
  final BitcoinOrdering outputOrdering;
  ForkedTransactionBuilder(
      {required this.outPuts,
      required this.fee,
      required this.network,
      required List<UtxoWithAddress> utxos,
      this.inputOrdering = BitcoinOrdering.bip69,
      this.outputOrdering = BitcoinOrdering.bip69,
      this.memo,
      this.enableRBF = false,
      this.isFakeTransaction = false})
      : utxosInfo = utxos {
    _validateBuilder();
  }

  void _validateBuilder() {
    if (network is! BitcoinCashNetwork && network is! BitcoinSVNetwork) {
      throw const MessageException(
          "invalid network. use ForkedTransactionBuilder for BitcoinCashNetwork and BSVNetwork otherwise use BitcoinTransactionBuilder");
    }
    for (final i in utxosInfo) {
      i.ownerDetails.address.toAddress(network);
    }
    for (final i in outPuts) {
      if (i is BitcoinOutput) {
        i.address.toAddress(network);
      }
    }
  }

  /// This method is used to create a dummy transaction,
  /// allowing us to obtain the size of the original transaction
  /// before conducting the actual transaction. This helps us estimate the transaction cost
  static int estimateTransactionSize(
      {required List<UtxoWithAddress> utxos,
      required List<BitcoinBaseOutput> outputs,
      required BitcoinCashNetwork network,
      String? memo,
      bool enableRBF = false}) {
    final transactionBuilder = ForkedTransactionBuilder(

        /// Now, we provide the UTXOs we want to spend.
        utxos: utxos,

        /// We select transaction outputs
        outPuts: outputs,

        /// Transaction fee
        /// Ensure that you have accurately calculated the amounts.
        /// If the sum of the outputs, including the transaction fee,
        /// does not match the total amount of UTXOs,
        /// it will result in an error. Please double-check your calculations.
        fee: BigInt.from(10000000000000),

        /// network, testnet, mainnet
        network: network,

        /// If you like the note write something else and leave it blank
        memo: memo,

        /// RBF, or Replace-By-Fee, is a feature in Bitcoin that allows you to increase the fee of an unconfirmed
        /// transaction that you've broadcasted to the network.
        /// This feature is useful when you want to speed up a
        /// transaction that is taking longer than expected to get confirmed due to low transaction fees.
        enableRBF: true,

        /// We consider the transaction to be fake so that it doesn't check the amounts
        /// and doesn't generate errors when determining the transaction size.
        isFakeTransaction: true);

    /// 71 bytes (64 byte signature, 6-7 byte Der encoding length)
    const String fakeECDSASignatureBytes =
        "0101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101";

    final transaction = transactionBuilder
        .buildTransaction((trDigest, utxo, multiSigPublicKey, int sighash) {
      return fakeECDSASignatureBytes;
    });

    /// Now we need the size of the transaction.
    final size = transaction.getSize();

    return size;
  }

  /// It is used to make the appropriate scriptSig
  Script _buildInputScriptPubKeys(UtxoWithAddress utxo) {
    if (utxo.isMultiSig()) {
      final script = utxo.multiSigAddress.multiSigScript;
      switch (utxo.utxo.scriptType) {
        case P2shAddressType.p2pkhInP2sh:
        case P2shAddressType.p2pkhInP2shwt:
        case P2shAddressType.p2pkhInP2sh32:
        case P2shAddressType.p2pkhInP2sh32wt:
          return script;
        default:
          throw ArgumentError(
              "unsuported multi-sig type ${utxo.utxo.scriptType} for ${network.conf.coinName.name}");
      }
    }

    final senderPub = utxo.public();
    switch (utxo.utxo.scriptType) {
      case PubKeyAddressType.p2pk:
      case P2shAddressType.p2pkInP2sh:
      case P2shAddressType.p2pkInP2shwt:
      case P2shAddressType.p2pkInP2sh32:
      case P2shAddressType.p2pkInP2sh32wt:
        return senderPub.toRedeemScript();
      case P2pkhAddressType.p2pkh:
      case P2shAddressType.p2pkhInP2sh:
      case P2shAddressType.p2pkhInP2sh32:
      case P2pkhAddressType.p2pkhwt:
      case P2shAddressType.p2pkhInP2shwt:
      case P2shAddressType.p2pkhInP2sh32wt:
        return senderPub.toAddress().toScriptPubKey();
      default:
        throw MessageException(
            "${utxo.utxo.scriptType} does not sudpport on ${network.conf.coinName.name}");
    }
  }

  /// generateTransactionDigest generates and returns a transaction digest for a given input in the context of a Bitcoin
  /// transaction. The digest is used for signing the transaction input. The function takes into account whether the
  /// associated UTXO is Segregated Witness (SegWit) or Pay-to-Taproot (P2TR), and it computes the appropriate digest
  /// based on these conditions.
//
  /// Parameters:
  /// - scriptPubKeys: representing the scriptPubKey for the transaction output being spent.
  /// - input: An integer indicating the index of the input being processed within the transaction.
  /// - utox: A UtxoWithAddress instance representing the unspent transaction output (UTXO) associated with the input.
  /// - transaction: A BtcTransaction representing the Bitcoin transaction being constructed.
  /// - taprootAmounts: A List of BigInt containing taproot-specific amounts for P2TR inputs (ignored for non-P2TR inputs).
  /// - tapRootPubKeys: A List of of Script representing taproot public keys for P2TR inputs (ignored for non-P2TR inputs).
//
  /// Returns:
  /// - List<int>: representing the transaction digest to be used for signing the input.
  List<int> _generateTransactionDigest(
    Script scriptPubKeys,
    int input,
    UtxoWithAddress utox,
    BtcTransaction transaction,
  ) {
    return transaction.getTransactionSegwitDigit(
        txInIndex: input,
        script: scriptPubKeys,
        amount: utox.utxo.value,
        token: utox.utxo.token,
        sighash:
            BitcoinOpCodeConst.SIGHASH_ALL | BitcoinOpCodeConst.SIGHASH_FORKED);
  }

  /// buildP2wshOrP2shScriptSig constructs and returns a script signature (represented as a List of strings)
  /// for a Pay-to-Witness-Script-Hash (P2WSH) or Pay-to-Script-Hash (P2SH) input. The function combines the
  /// signed transaction digest with the script details of the multi-signature address owned by the UTXO owner.
  //
  /// Parameters:
  /// - signedDigest: A List of strings containing the signed transaction digest elements.
  /// - utx: A UtxoWithAddress instance representing the unspent transaction output (UTXO) and its owner details.
  //
  /// Returns:
  /// - List<String>: A List of strings representing the script signature for the P2WSH or P2SH input.
  List<String> _buildMiltisigUnlockingScript(
      List<String> signedDigest, UtxoWithAddress utx) {
    /// The constructed script signature consists of the signed digest elements followed by
    /// the script details of the multi-signature address.
    return ['', ...signedDigest, utx.multiSigAddress.multiSigScript.toHex()];
  }

/*
Unlocking Script (scriptSig): The scriptSig is also referred to as
the unlocking script because it provides data and instructions to unlock
a specific output. It contains information and cryptographic signatures
that demonstrate the right to spend the bitcoins associated with the corresponding scriptPubKey output.
*/
  List<String> _buildUnlockingScript(String signedDigest, UtxoWithAddress utx) {
    final senderPub = utx.public();
    switch (utx.utxo.scriptType) {
      case PubKeyAddressType.p2pk:
        return [signedDigest];
      case P2pkhAddressType.p2pkh:
      case P2pkhAddressType.p2pkhwt:
        return [signedDigest, senderPub.toHex()];
      case P2shAddressType.p2pkhInP2sh:
      case P2shAddressType.p2pkhInP2shwt:
      case P2shAddressType.p2pkhInP2sh32:
      case P2shAddressType.p2pkhInP2sh32wt:
        final script = senderPub.toAddress().toScriptPubKey();
        return [signedDigest, senderPub.toHex(), script.toHex()];
      case P2shAddressType.p2pkInP2sh:
      case P2shAddressType.p2pkInP2shwt:
      case P2shAddressType.p2pkInP2sh32:
      case P2shAddressType.p2pkInP2sh32wt:
        final script = senderPub.toRedeemScript();
        return [signedDigest, script.toHex()];
      default:
        throw Exception(
            'Cannot send from this type of address ${utx.utxo.scriptType}');
    }
  }

  Tuple<List<TxInput>, List<UtxoWithAddress>> _buildInputs() {
    List<UtxoWithAddress> sortedUtxos = List.from(utxosInfo);

    if (inputOrdering == BitcoinOrdering.shuffle) {
      sortedUtxos = sortedUtxos..shuffle();
    } else if (inputOrdering == BitcoinOrdering.bip69) {
      sortedUtxos = sortedUtxos
        ..sort(
          (a, b) {
            final txidComparison = a.utxo.txHash.compareTo(b.utxo.txHash);
            if (txidComparison == 0) {
              return a.utxo.vout - b.utxo.vout;
            }
            return txidComparison;
          },
        );
    }
    List<TxInput> inputs = sortedUtxos.map((e) => e.utxo.toInput()).toList();
    if (enableRBF && inputs.isNotEmpty) {
      inputs[0] = inputs[0]
          .copyWith(sequence: BitcoinOpCodeConst.REPLACE_BY_FEE_SEQUENCE);
    }
    return Tuple(List<TxInput>.unmodifiable(inputs),
        List<UtxoWithAddress>.unmodifiable(sortedUtxos));
  }

  List<TxOutput> _buildOutputs() {
    List<TxOutput> outputs = outPuts
        .where((element) => element is! BitcoinBurnableOutput)
        .map((e) => e.toOutput)
        .toList();

    if (memo != null) {
      outputs
          .add(TxOutput(amount: BigInt.zero, scriptPubKey: _opReturn(memo!)));
    }

    if (outputOrdering == BitcoinOrdering.shuffle) {
      outputs = outputs..shuffle();
    } else if (outputOrdering == BitcoinOrdering.bip69) {
      outputs = outputs
        ..sort(
          (a, b) {
            final valueComparison = a.amount.compareTo(b.amount);
            if (valueComparison == 0) {
              return BytesUtils.compareBytes(
                  a.scriptPubKey.toBytes(), b.scriptPubKey.toBytes());
            }
            return valueComparison;
          },
        );
    }
    return List<TxOutput>.unmodifiable(outputs);
  }

/*
The primary use case for OP_RETURN is data storage. You can embed various types of
data within the OP_RETURN output, such as text messages, document hashes, or metadata
related to a transaction. This data is permanently recorded on the blockchain and can
be retrieved by anyone who examines the blockchain's history.
*/
  Script _opReturn(String message) {
    final toHex = BytesUtils.toHexString(StringUtils.toBytes(message));
    return Script(script: ["OP_RETURN", toHex]);
  }

  /// Total amount to spend excluding fees
  BigInt _sumOutputAmounts(List<TxOutput> outputs) {
    BigInt sum = BigInt.zero;
    for (final e in outputs) {
      sum += e.amount;
    }
    return sum;
  }

  /// Total token amount to spend.
  Map<String, BigInt> _sumTokenOutputAmounts(List<TxOutput> outputs) {
    final Map<String, BigInt> tokens = {};
    for (var utxo in outputs) {
      if (utxo.cashToken == null) continue;
      final token = utxo.cashToken!;
      if (!token.hasAmount) continue;
      if (tokens.containsKey(token.category)) {
        tokens[token.category] = tokens[token.category]! + token.amount;
      } else {
        tokens[token.category] = token.amount;
      }
    }
    return tokens;
  }

  @override
  BtcTransaction buildTransaction(BitcoinSignerCallBack sign) {
    /// build inputs
    final sortedInputs = _buildInputs();

    final List<TxInput> inputs = sortedInputs.item1;

    final List<UtxoWithAddress> utxos = sortedInputs.item2;

    /// build outout
    final outputs = _buildOutputs();

    /// sum of amounts you filled in outputs
    final sumOutputAmounts = _sumOutputAmounts(outputs);

    /// sum of UTXOS amount
    final sumUtxoAmount = utxos.sumOfUtxosValue();

    /// sum of outputs amount + transcation fee
    final sumAmountsWithFee = (sumOutputAmounts + fee);

    /// We will check whether you have spent the correct amounts or not
    if (!isFakeTransaction && sumAmountsWithFee != sumUtxoAmount) {
      throw MessageException('Sum value of utxo not spending', details: {
        "inputAmount": sumUtxoAmount,
        "fee": fee,
        "outputAmount": sumOutputAmounts
      });
    }

    if (!isFakeTransaction) {
      /// sum of token amounts
      final sumOfTokenUtxos = utxos.sumOfTokenUtxos();

      /// sum of token output amounts
      final sumTokenOutputAmouts = _sumTokenOutputAmounts(outputs);
      for (final i in sumOfTokenUtxos.entries) {
        if (sumTokenOutputAmouts[i.key] != i.value) {
          BigInt amount = sumTokenOutputAmouts[i.key] ?? BigInt.zero;
          amount += outPuts
              .whereType<BitcoinBurnableOutput>()
              .where((element) => element.categoryID == i.key)
              .fold(
                  BigInt.zero,
                  (previousValue, element) =>
                      previousValue + (element.value ?? BigInt.zero));

          if (amount != i.value) {
            throw MessageException(
                'Sum token value of UTXOs not spending. use BitcoinBurnableOutput if you want to burn tokens.',
                details: {
                  "token": i.key,
                  "inputValue": i.value,
                  "outputValue": amount
                });
          }
        }
      }
      for (final i in utxos) {
        if (i.utxo.token != null) {
          final token = i.utxo.token!;
          if (token.hasAmount) continue;
          if (!token.hasNFT) continue;
          final hasOneoutput = outPuts.whereType<BitcoinTokenOutput>().any(
              (element) =>
                  element.utxoHash == i.utxo.txHash &&
                  element.token.category == token.category);
          if (hasOneoutput) continue;
          final hasBurnableOutput = outPuts
              .whereType<BitcoinBurnableOutput>()
              .any((element) =>
                  element.utxoHash == i.utxo.txHash &&
                  element.categoryID == token.category);
          if (hasBurnableOutput) continue;
          throw MessageException(
              'Some NFTs in the inputs lack the corresponding spending in the outputs. If you intend to burn tokens, consider utilizing the BitcoinBurnableOutput.',
              details: {"category id": token.category});
        }
      }
    }

    /// create new transaction with inputs and outputs and isSegwit transaction or not
    final transaction =
        BtcTransaction(inputs: inputs, outputs: outputs, hasSegwit: false);

    const int sighash =
        BitcoinOpCodeConst.SIGHASH_ALL | BitcoinOpCodeConst.SIGHASH_FORKED;

    /// Well, now let's do what we want for each input
    for (int i = 0; i < inputs.length; i++) {
      final indexUtxo = utxos[i];

      /// We receive the owner's ScriptPubKey
      final script = _buildInputScriptPubKeys(indexUtxo);

      /// We generate transaction digest for current input
      final digest =
          _generateTransactionDigest(script, i, indexUtxo, transaction);

      /// handle multisig address
      if (indexUtxo.isMultiSig()) {
        final multiSigAddress = indexUtxo.multiSigAddress;
        int sumMultiSigWeight = 0;
        final mutlsiSigSignatures = <String>[];
        for (int ownerIndex = 0;
            ownerIndex < multiSigAddress.signers.length;
            ownerIndex++) {
          /// now we need sign the transaction digest
          final sig = sign(digest, indexUtxo,
              multiSigAddress.signers[ownerIndex].publicKey, sighash);
          if (sig.isEmpty) continue;
          for (int weight = 0;
              weight < multiSigAddress.signers[ownerIndex].weight;
              weight++) {
            if (mutlsiSigSignatures.length >= multiSigAddress.threshold) {
              break;
            }
            mutlsiSigSignatures.add(sig);
          }
          sumMultiSigWeight += multiSigAddress.signers[ownerIndex].weight;
          if (sumMultiSigWeight >= multiSigAddress.threshold) {
            break;
          }
        }
        if (sumMultiSigWeight != multiSigAddress.threshold) {
          throw StateError("some multisig signature does not exist");
        }

        _addScripts(
            input: inputs[i], signatures: mutlsiSigSignatures, utxo: indexUtxo);
        continue;
      }

      /// now we need sign the transaction digest
      final sig = sign(digest, indexUtxo, indexUtxo.public().toHex(), sighash);
      _addScripts(input: inputs[i], signatures: [sig], utxo: indexUtxo);
    }

    return transaction;
  }

  void _addScripts({
    required UtxoWithAddress utxo,
    required TxInput input,
    required List<String> signatures,
  }) {
    /// ok we signed, now we need unlocking script for this input
    final scriptSig = utxo.isMultiSig()
        ? _buildMiltisigUnlockingScript(signatures, utxo)
        : _buildUnlockingScript(signatures.first, utxo);

    input.scriptSig = Script(script: scriptSig);
  }
  
  @override
  Future<BtcTransaction> buildTransactionAsync(BitcoinSignerAsyncCallBack sign) {
    // TODO: implement buildTransactionAsync
    throw UnimplementedError();
  }
}
