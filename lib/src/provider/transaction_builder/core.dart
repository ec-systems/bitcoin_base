import 'package:bitcoin_base/bitcoin_base.dart';

typedef BitcoinSignerCallBack = String Function(
    List<int> trDigest, UtxoWithAddress utxo, String publicKey, int sighash);
typedef BitcoinSignerAsyncCallBack = Future<String> Function(
    List<int> trDigest, UtxoWithAddress utxo, String publicKey, int sighash);

abstract class BasedBitcoinTransacationBuilder {
  BtcTransaction buildTransaction(BitcoinSignerCallBack sign);
  Future<BtcTransaction> buildTransactionAsync(BitcoinSignerAsyncCallBack sign);
}

enum BitcoinOrdering { bip69, shuffle, none }
