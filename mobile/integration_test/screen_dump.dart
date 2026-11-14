import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

String screenTexts({int limit = 40}) {
  final texts = <String>[];
  final seen = <String>{};
  final whitespace = RegExp(r'\s+');
  final elements = find
      .byWidgetPredicate((widget) => widget is Text || widget is EditableText)
      .evaluate();
  for (final element in elements) {
    final widget = element.widget;
    final text =
        (widget is Text
                ? widget.data ?? widget.textSpan!.toPlainText()
                : (widget as EditableText).controller.text)
            .replaceAll(whitespace, ' ')
            .trim();
    if (text.isEmpty || !seen.add(text)) continue;
    if (texts.length >= limit) {
      texts.add('…');
      break;
    }
    texts.add(text);
  }
  return texts.isEmpty ? '(на экране нет текста)' : texts.join(' | ');
}
