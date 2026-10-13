import 'dart:typed_data';

import 'embedded_font.dart';
import 'page_overlay_painter.dart';
import 'pdf_object.dart';
import 'pdf_reader.dart';
import 'pdf_writer.dart';
import 'ttf_font.dart';

/// Coordinates every page injection of one document and writes a single
/// incremental update at the end.
///
/// Only the page objects that actually changed are duplicated (plus their
/// ancestors in the page tree), so a 600 page book gets one small update
/// section instead of a rewritten file.
class PdfInjectionSession {
  PdfInjectionSession(this.reader) : writer = PdfIncrementalWriter(reader);

  final PdfFileReader reader;
  final PdfIncrementalWriter writer;

  final List<EmbeddedFont> _fonts = [];
  final Map<int, _PendingPage> _pending = {};

  List<EmbeddedFont> get fonts => List.unmodifiable(_fonts);

  /// Embeds a TTF that will be available to every page of this session.
  EmbeddedFont addFont(TtfFont font, String name) {
    final embedded = EmbeddedFont(writer, font, name, _fonts.length + 1);
    _fonts.add(embedded);
    return embedded;
  }

  /// Creates the painter that collects the drawing ops of [pageIndex].
  PageOverlayPainter painterFor(int pageIndex) => PageOverlayPainter(pageIndex);

  /// Commits a finished painter into the session.
  void commit(PageOverlayPainter painter) {
    _register(painter.pageIndex, painter);
  }

  void _register(int pageIndex, PageOverlayPainter painter) {
    final refs = writer.reserve(3);
    final streamRef = refs[0];
    final resourcesRef = refs[1];
    final pageRef = refs[2];

    final path = reader.pagePath(pageIndex);
    final oldPageRef = path.pageRef;
    final oldPage = reader.getObject(oldPageRef.objNum);
    if (oldPage is! Map<String, Object?>) {
      throw const PdfParseException('page object could not be read');
    }

    // ---- resources: inherit from the page tree, page wins, then add ours ----
    final merged = <String, Object?>{};
    for (final ancestor in path.ancestors) {
      final res = _resourcesOf(ancestor.dict);
      if (res != null) merged.addAll(res);
    }
    final own = _resourcesOf(oldPage);
    if (own != null) merged.addAll(own);

    final fonts = <String, Object?>{};
    final existingFonts = merged['Font'];
    if (existingFonts is Map) {
      for (final e in existingFonts.entries) {
        fonts['${e.key}'] = e.value;
      }
    }
    final names = <int, String>{};
    for (final f in _fonts) {
      var name = 'SLF${f.tag}';
      var i = 0;
      while (fonts.containsKey(name)) {
        i++;
        name = 'SLF${f.tag}_$i';
      }
      names[f.tag] = name;
      fonts[name] = f.type0Ref;
    }
    merged['Font'] = fonts;
    writer.write(resourcesRef, PdfSerializer.write(merged));

    writer.writeStream(
      streamRef,
      '/Filter /FlateDecode',
      painter.buildContentStream(names),
    );

    _pending[oldPageRef.objNum] = _PendingPage(
      streamRef: streamRef,
      resourcesRef: resourcesRef,
      newPageRef: pageRef,
      oldPage: oldPage,
      oldPageRef: oldPageRef,
      ancestors: path.ancestors,
    );
  }

  Map<String, Object?>? _resourcesOf(Map<String, Object?> node) {
    final res = node['Resources'];
    if (res == null) return null;
    final resolved = res is PdfRef ? reader.getObject(res.objNum) : res;
    return resolved is Map<String, Object?> ? resolved : null;
  }

  /// Writes everything and returns the finished document.
  Uint8List finalize() {
    for (final f in _fonts) {
      f.finish();
    }

    // 1. rebuild only the branches of the page tree that lead to a changed page
    final pendingNodes = <({PdfRef ref, Map<String, Object?> dict, List<Object?> kids})>[];
    final parentsOf = <int, PdfRef>{};

    PdfRef walk(PdfRef ref) {
      final node = reader.getObject(ref.objNum);
      if (node is! Map<String, Object?>) return ref;
      final kids = node['Kids'];
      if (kids is! List<Object?>) return ref;
      var changed = false;
      final newKids = <Object?>[];
      for (final kid in kids) {
        if (kid is! PdfRef) {
          newKids.add(kid);
          continue;
        }
        final child = reader.getObject(kid.objNum);
        // A /Page never carries /Kids; some producers omit /Type on the
        // intermediate nodes, so /Kids is the reliable discriminator.
        final isPagesNode = child is Map<String, Object?> && child.containsKey('Kids');
        if (isPagesNode) {
          final sub = walk(kid);
          newKids.add(sub);
          if (sub.objNum != kid.objNum) changed = true;
        } else if (_pending.containsKey(kid.objNum)) {
          final replacement = _pending[kid.objNum]!.newPageRef;
          newKids.add(replacement);
          changed = true;
        } else {
          newKids.add(kid);
        }
      }
      if (!changed) return ref;
      final newRef = writer.reserve(1).first;
      pendingNodes.add((ref: newRef, dict: node, kids: newKids));
      for (final k in newKids) {
        if (k is PdfRef) parentsOf[k.objNum] = newRef;
      }
      return newRef;
    }

    final rootPages = reader.catalog['Pages'];
    final newRootPages = rootPages is PdfRef ? walk(rootPages) : null;
    for (final node in pendingNodes) {
      final dict = Map<String, Object?>.of(node.dict)..['Kids'] = node.kids;
      writer.write(node.ref, PdfSerializer.write(dict));
    }

    // 2. write the modified page objects
    for (final page in _pending.values) {
      final dict = Map<String, Object?>.of(page.oldPage);
      final contents = dict['Contents'];
      final newContents = <Object?>[
        if (contents is PdfRef) contents,
        if (contents is List<Object?>) ...contents,
        page.streamRef,
      ];
      dict['Contents'] = newContents;
      dict['Resources'] = page.resourcesRef;
      final parent = parentsOf[page.newPageRef.objNum];
      if (parent != null) {
        dict['Parent'] = parent;
      } else if (dict['Parent'] == null && page.ancestors.isNotEmpty) {
        dict['Parent'] = PdfRef(page.ancestors.last.objNum);
      }
      writer.write(page.newPageRef, PdfSerializer.write(dict));
    }

    // 3. new catalog when the page tree changed
    PdfRef rootRef;
    if (newRootPages != null && rootPages is PdfRef) {
      final catalog = Map<String, Object?>.of(reader.catalog)
        ..['Pages'] = newRootPages;
      final catalogRef = writer.reserve(1).first;
      writer.write(catalogRef, PdfSerializer.write(catalog));
      rootRef = catalogRef;
    } else {
      rootRef = reader.trailer['Root'] is PdfRef
          ? reader.trailer['Root']! as PdfRef
          : PdfRef(1);
    }

    return writer.finalize(rootRef);
  }
}

class _PendingPage {
  const _PendingPage({
    required this.streamRef,
    required this.resourcesRef,
    required this.newPageRef,
    required this.oldPage,
    required this.oldPageRef,
    required this.ancestors,
  });

  final PdfRef streamRef;
  final PdfRef resourcesRef;
  final PdfRef newPageRef;
  final Map<String, Object?> oldPage;
  final PdfRef oldPageRef;
  final List<({int objNum, Map<String, Object?> dict})> ancestors;
}
