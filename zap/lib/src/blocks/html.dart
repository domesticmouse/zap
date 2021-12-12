import 'dart:html';

import '../core/fragment.dart';

/// Inserts raw HTML into the document without any sanitization.
class HtmlTag extends Fragment {
  String _rawHtml;

  /// An artificial element that we never insert into the document.
  ///
  /// We call `innerHtml` on this element to obtain the nodes that need to be
  /// inserted into the actual document.
  final Element _artificialParent = Element.div();
  Element? _mountTarget;
  Node? _mountAnchor;

  List<Node>? _children;

  HtmlTag(this._rawHtml);

  set rawHtml(String html) {
    _rawHtml = html;

    // Re-create children
    destroy();
    create();

    if (_mountTarget != null) {
      mount(_mountTarget!, _mountAnchor);
    }
  }

  @override
  void create() {
    // ignore: unsafe_html
    _artificialParent.setInnerHtml(_rawHtml,
        treeSanitizer: NodeTreeSanitizer.trusted);

    // [Element.children] is a view, but we want a fixed snapshot of the current
    // children, so copy.
    _children = _artificialParent.children.toList();
  }

  @override
  void mount(Element target, [Node? anchor]) {
    _mountTarget = target;
    _mountAnchor = anchor;

    final children = _children;
    if (children != null) {
      for (final child in children) {
        target.insertBefore(child, anchor);
      }
    }
  }

  @override
  void update(int delta) {}

  @override
  void destroy() {
    final children = _children;
    if (children != null) {
      for (final child in children) {
        child.remove();
      }
    }
    _children = null;
  }
}
