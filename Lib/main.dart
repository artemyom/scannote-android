import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const ScanNote());

class ScanNote extends StatelessWidget {
  const ScanNote({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ScanNote', debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const Editor(),
  );
}

enum Tool { pen, text, eraser }
class Stroke {
  Stroke(this.points, this.color, this.width);
  final List<Offset> points; // normalized coordinates 0..1
  final Color color;
  final double width;
}
class NoteText {
  NoteText(this.position, this.value, this.color);
  final Offset position; // normalized
  final String value;
  final Color color;
}
class PageData {
  PageData(this.background);
  final Uint8List background;
  final List<Stroke> strokes = [];
  final List<NoteText> texts = [];
}

class Editor extends StatefulWidget {
  const Editor({super.key});
  @override
  State<Editor> createState() => _EditorState();
}
class _EditorState extends State<Editor> {
  final List<PageData> pages = [];
  final GlobalKey pageKey = GlobalKey();
  Tool tool = Tool.pen;
  Color ink = Colors.blue.shade800;
  double penWidth = 2.8;
  int current = 0;
  bool busy = false;
  Stroke? active;
  String? filename;

  Future<void> openFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom,
      allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg']);
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    setState(() => busy = true);
    try {
      final loaded = <PageData>[];
      if (path.toLowerCase().endsWith('.pdf')) {
        final doc = await PdfDocument.openFile(path);
        try {
          for (var n = 1; n <= doc.pagesCount; n++) {
            final page = await doc.getPage(n);
            try {
              final factor = math.min(2.0, 1800 / math.max(page.width, page.height));
              final rendered = await page.render(width: page.width * factor,
                height: page.height * factor, format: PdfPageImageFormat.png);
              if (rendered != null) loaded.add(PageData(rendered.bytes));
            } finally { await page.close(); }
          }
        } finally { await doc.close(); }
      } else {
        loaded.add(PageData(await File(path).readAsBytes()));
      }
      if (loaded.isEmpty) throw Exception('Не удалось прочитать страницы');
      setState(() { pages..clear()..addAll(loaded); current = 0; filename = result.files.single.name; });
    } catch (e) { showMessage('Ошибка открытия: $e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  void showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> addText(Offset point) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Добавить текст'),
      content: TextField(controller: controller, autofocus: true, maxLines: 5,
        decoration: const InputDecoration(hintText: 'Введите ответ')),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Вставить'))],
    ));
    controller.dispose();
    if (value != null && value.trim().isNotEmpty && mounted) {
      setState(() => pages[current].texts.add(NoteText(point, value, ink)));
    }
  }

  Offset normalize(Offset point, Size size) => Offset(
    (point.dx / size.width).clamp(0.0, 1.0),
    (point.dy / size.height).clamp(0.0, 1.0));

  void eraseAt(Offset p) {
    final page = pages[current];
    const radius = 0.025;
    setState(() {
      page.strokes.removeWhere((s) => s.points.any((q) => (q-p).distance < radius));
      page.texts.removeWhere((t) => (t.position-p).distance < radius);
    });
  }

  void undo() {
    if (pages.isEmpty) return;
    final p = pages[current];
    setState(() { if (p.strokes.isNotEmpty) { p.strokes.removeLast(); }
      else if (p.texts.isNotEmpty) { p.texts.removeLast(); } });
  }

  Future<void> exportPdf() async {
    if (pages.isEmpty) return;
    setState(() => busy = true);
    try {
      final document = pw.Document();
      for (var i = 0; i < pages.length; i++) {
        final bytes = await renderPage(i);
        final decoded = img.decodeImage(bytes)!;
        document.addPage(pw.Page(
          pageFormat: PdfPageFormat(decoded.width.toDouble(), decoded.height.toDouble()),
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.fill),
        ));
      }
      final dir = await getTemporaryDirectory();
      final output = File('${dir.path}/ScanNote_${DateTime.now().millisecondsSinceEpoch}.pdf');
      await output.writeAsBytes(await document.save());
      await Share.shareXFiles([XFile(output.path)], text: 'Заполненное задание ScanNote');
    } catch (e) { showMessage('Ошибка экспорта: $e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<Uint8List> renderPage(int index) async {
    // Export uses the same normalized annotation model as the on-screen painter.
    final page = pages[index];
    final codec = await ui.instantiateImageCodec(page.background);
    final frame = await codec.getNextFrame();
    final background = frame.image;
    final w = background.width.toDouble();
    final h = background.height.toDouble();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(background, Offset.zero, Paint());
    for (final s in page.strokes) {
      if (s.points.isEmpty) continue;
      final paint = Paint()..color = s.color..strokeWidth = s.width * (w / 700)
        ..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round..style = PaintingStyle.stroke;
      if (s.points.length == 1) {
        canvas.drawCircle(Offset(s.points.first.dx*w, s.points.first.dy*h), paint.strokeWidth/2, Paint()..color=s.color);
      } else {
        final path = Path()..moveTo(s.points.first.dx*w, s.points.first.dy*h);
        for (final p in s.points.skip(1)) { path.lineTo(p.dx*w, p.dy*h); }
        canvas.drawPath(path, paint);
      }
    }
    for (final t in page.texts) {
      final painter = TextPainter(text: TextSpan(text: t.value,
        style: TextStyle(color: t.color, fontSize: 18 * (w / 700))),
        textDirection: TextDirection.ltr, maxLines: null);
      painter.layout(maxWidth: w * (1-t.position.dx).clamp(0.05, 1.0));
      painter.paint(canvas, Offset(t.position.dx*w, t.position.dy*h));
    }
    final picture = recorder.endRecording();
    final result = await picture.toImage(background.width, background.height);
    final data = await result.toByteData(format: ui.ImageByteFormat.png);
    background.dispose(); result.dispose(); picture.dispose();
    return data!.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(filename == null ? 'ScanNote' : 'ScanNote · $filename'),
        actions: [IconButton(tooltip: 'Открыть файл', onPressed: busy ? null : openFile, icon: const Icon(Icons.folder_open)),
          IconButton(tooltip: 'Экспорт PDF', onPressed: busy || pages.isEmpty ? null : exportPdf,
            icon: const Icon(Icons.ios_share))]),
      body: Column(children: [
        if (busy) const LinearProgressIndicator(),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          toolButton(Tool.pen, Icons.draw, 'Ручка'),
          toolButton(Tool.text, Icons.text_fields, 'Текст'),
          toolButton(Tool.eraser, Icons.auto_fix_off, 'Ластик'),
          IconButton(tooltip: 'Отменить', onPressed: undo, icon: const Icon(Icons.undo)),
          IconButton(tooltip: 'Синий', onPressed: () => setState(() => ink=Colors.blue.shade800), icon: const Icon(Icons.circle, color: Colors.blue)),
          IconButton(tooltip: 'Чёрный', onPressed: () => setState(() => ink=Colors.black), icon: const Icon(Icons.circle, color: Colors.black)),
          IconButton(tooltip: 'Красный', onPressed: () => setState(() => ink=Colors.red), icon: const Icon(Icons.circle, color: Colors.red)),
          const Text('Толщина'),
          SizedBox(width: 125, child: Slider(value: penWidth, min: 1, max: 10,
            onChanged: (v) => setState(() => penWidth=v))),
        ])),
        Expanded(child: pages.isEmpty ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.picture_as_pdf_outlined, size: 72), const SizedBox(height: 12),
          const Text('Откройте PDF или фотографию задания'), const SizedBox(height: 12),
          FilledButton.icon(onPressed: openFile, icon: const Icon(Icons.add), label: const Text('Открыть скан')),
        ])) : LayoutBuilder(builder: (context, constraints) {
          final p = pages[current];
          return Center(child: InteractiveViewer(minScale: 0.5, maxScale: 5,
            child: Padding(padding: const EdgeInsets.all(12), child: ImagePage(
              key: ValueKey(current), page: p, tool: tool, ink: ink, penWidth: penWidth,
              onStrokeStart: (point) => setState(() { active=Stroke([point], ink, penWidth); p.strokes.add(active!); }),
              onStrokeUpdate: (point) => setState(() => active?.points.add(point)),
              onStrokeEnd: () => active=null,
              onText: addText, onErase: eraseAt,
            ))));
        })),
        if (pages.isNotEmpty) Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(onPressed: current>0 ? () => setState(() => current--) : null,
            icon: const Icon(Icons.chevron_left)),
          Text('Страница ${current+1} из ${pages.length}'),
          IconButton(onPressed: current+1<pages.length ? () => setState(() => current++) : null,
            icon: const Icon(Icons.chevron_right)),
        ]),
      ]),
    );
  }
  Widget toolButton(Tool value, IconData icon, String label) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: FilledButton.tonalIcon(onPressed: () => setState(() => tool=value),
      style: FilledButton.styleFrom(backgroundColor: tool==value ? Colors.indigo.shade100 : null),
      icon: Icon(icon), label: Text(label)));
}

class ImagePage extends StatelessWidget {
  const ImagePage({super.key, required this.page, required this.tool, required this.ink,
    required this.penWidth, required this.onStrokeStart, required this.onStrokeUpdate,
    required this.onStrokeEnd, required this.onText, required this.onErase});
  final PageData page;
  final Tool tool;
  final Color ink;
  final double penWidth;
  final ValueChanged<Offset> onStrokeStart, onStrokeUpdate, onText, onErase;
  final VoidCallback onStrokeEnd;
  @override
  Widget build(BuildContext context) {
    final image = img.decodeImage(page.background)!;
    return AspectRatio(aspectRatio: image.width/image.height,
      child: LayoutBuilder(builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        Offset norm(Offset p) => Offset((p.dx/size.width).clamp(0,1).toDouble(),
          (p.dy/size.height).clamp(0,1).toDouble());
        return Stack(fit: StackFit.expand, children: [
          Image.memory(page.background, fit: BoxFit.fill, gaplessPlayback: true),
          CustomPaint(painter: Annotations(page)),
          GestureDetector(behavior: HitTestBehavior.opaque,
            onPanStart: tool==Tool.text ? null : (d) {
              if (tool==Tool.pen) onStrokeStart(norm(d.localPosition));
              else onErase(norm(d.localPosition));
            },
            onPanUpdate: tool==Tool.text ? null : (d) {
              if (tool==Tool.pen) onStrokeUpdate(norm(d.localPosition));
              else onErase(norm(d.localPosition));
            },
            onPanEnd: tool==Tool.text ? null : (_) => onStrokeEnd(),
            onTapUp: tool==Tool.text ? (d) => onText(norm(d.localPosition)) : null),
        ]);
      }));
  }
}
class Annotations extends CustomPainter {
  Annotations(this.page);
  final PageData page;
  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in page.strokes) {
      if (stroke.points.isEmpty) continue;
      final paint = Paint()..color=stroke.color..strokeWidth=stroke.width*size.width/700
        ..strokeCap=StrokeCap.round..strokeJoin=StrokeJoin.round..style=PaintingStyle.stroke;
      final first = Offset(stroke.points.first.dx*size.width, stroke.points.first.dy*size.height);
      if (stroke.points.length==1) { canvas.drawCircle(first, paint.strokeWidth/2, Paint()..color=stroke.color); continue; }
      final path = Path()..moveTo(first.dx, first.dy);
      for (final p in stroke.points.skip(1)) { path.lineTo(p.dx*size.width, p.dy*size.height); }
      canvas.drawPath(path, paint);
    }
    for (final t in page.texts) {
      final painter = TextPainter(text: TextSpan(text:t.value,
        style: TextStyle(fontSize:18*size.width/700, color:t.color)), textDirection: TextDirection.ltr);
      painter.layout(maxWidth:size.width*(1-t.position.dx).clamp(0.05,1.0));
      painter.paint(canvas, Offset(t.position.dx*size.width,t.position.dy*size.height));
    }
  }
  @override
  bool shouldRepaint(covariant Annotations oldDelegate) => true;
}
