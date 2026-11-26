import 'package:flutter/material.dart';

/// Bottom-sheet body that never runs off the screen: on small phones or with a large system
/// font the content scrolls instead of being cut off (1.3.194: the "?" sheet hid «Сообщить о
/// проблеме», «Поддержать автора» and the version line on iPhones). Up to 92 % of the screen;
/// use with `isScrollControlled: true` so the sheet may grow past the default 9/16.
class SheetScroll extends StatelessWidget {
  const SheetScroll({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: (mq.size.height - mq.padding.top) * .92),
      child: SingleChildScrollView(child: child),
    );
  }
}
