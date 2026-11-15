import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'app_log.dart';
import 'support.dart';

/// Tips through the store's own in-app purchases (App Store / Google Play builds only:
/// the stores don't allow outside donation links). Three consumable products; they unlock
/// nothing. Until the products exist in App Store Connect / Play Console, [products] stays
/// empty and the tip button is hidden.
class TipJar extends ChangeNotifier {
  TipJar._();
  static final instance = TipJar._();

  /// Same ids in App Store Connect and Google Play Console (consumable / one-time products).
  static const ids = {'tvc_tip_1', 'tvc_tip_3', 'tvc_tip_10'};

  List<ProductDetails> products = const [];
  bool busy = false;
  /// Bumped after every completed tip, for the "thank you".
  int thanks = 0;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  static bool get supported => Support.storeBuild && (Platform.isIOS || Platform.isAndroid);

  Future<void> init() async {
    if (!supported || _sub != null) return;
    try {
      final iap = InAppPurchase.instance;
      _sub = iap.purchaseStream.listen(_onPurchases, onError: (Object e) => AppLog.error('tips', e));
      if (!await iap.isAvailable()) return;
      final r = await iap.queryProductDetails(ids);
      if (r.error != null) AppLog.error('tips', r.error!.message);
      products = [...r.productDetails]..sort((a, b) => a.rawPrice.compareTo(b.rawPrice));
      notifyListeners();
    } catch (e) {
      AppLog.error('tips', e);
    }
  }

  Future<void> buy(ProductDetails p) async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      await InAppPurchase.instance.buyConsumable(purchaseParam: PurchaseParam(productDetails: p));
    } catch (e) {
      AppLog.error('tips', e);
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> list) async {
    for (final p in list) {
      if (p.status == PurchaseStatus.pending) continue;
      if (p.status == PurchaseStatus.purchased || p.status == PurchaseStatus.restored) thanks++;
      if (p.status == PurchaseStatus.error) AppLog.error('tips', p.error?.message ?? 'error');
      if (p.pendingCompletePurchase) {
        try {
          await InAppPurchase.instance.completePurchase(p);
        } catch (e) {
          AppLog.error('tips', e);
        }
      }
      busy = false;
    }
    notifyListeners();
  }
}
