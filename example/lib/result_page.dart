import 'dart:io';

import 'package:monokit/monokit.dart';
import 'package:monolens/monolens.dart';
import 'package:video_player/video_player.dart';

import 'ui/lens_chrome.dart';

/// What came out the other end — the export's own numbers, read back off disk.
///
/// Worth a screen of its own because the numbers are the claim: an edit that
/// says it cropped to 1080 should produce a file that is 1080 wide, and this is
/// where that gets checked by eye.
class ResultPage extends StatefulWidget {
  const ResultPage({required this.media, super.key});

  final CapturedMedia media;

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> {
  VideoPlayerController? _player;

  @override
  void initState() {
    super.initState();
    final media = widget.media;
    if (media is CapturedVideo) {
      _player = VideoPlayerController.file(File(media.path))
        ..initialize().then((_) {
          if (mounted) setState(() {});
          _player?.setLooping(true);
          _player?.play();
        });
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  static String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(0)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _seconds(Duration value) =>
      '${(value.inMilliseconds / 1000).toStringAsFixed(2)}s';

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return MonoScreen(
      background: theme.colors.canvas,
      safeArea: const MonoSafeArea.none(),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Padding(
                  // The back button floats over this pane, so centring against
                  // the raw pane would leave all the slack below the media.
                  padding: EdgeInsets.only(
                    top: MediaQuery.paddingOf(context).top + 60,
                  ),
                  child: Center(child: _preview()),
                ),
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LensScrim(height: 130),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(bottom: false, child: _header()),
                ),
              ],
            ),
          ),
          _details(),
        ],
      ),
    );
  }

  Widget _preview() {
    final media = widget.media;
    final player = _player;

    return switch (media) {
      CapturedImage() => Image.file(File(media.path)),
      CapturedVideo() when player != null && player.value.isInitialized =>
        AspectRatio(
          aspectRatio: player.value.aspectRatio,
          child: VideoPlayer(player),
        ),
      _ => const MonoSpinner(),
    };
  }

  Widget _header() {
    final theme = MonokitTheme.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: theme.spacing.md,
        vertical: theme.spacing.sm,
      ),
      child: Row(
        children: [
          LensChromeButton(
            semanticLabel: 'Back to the editor',
            onPressed: () => Navigator.of(context).pop(),
            child: MonoIcon(
              MonoIcons.chevronLeft,
              size: 18,
              color: theme.colors.onMedia,
            ),
          ),
        ],
      ),
    );
  }

  Widget _details() {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;
    final media = widget.media;

    return Container(
      decoration: BoxDecoration(
        color: colors.page,
        border: Border(top: BorderSide(color: colors.separator)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.all(theme.spacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Export complete',
                    style: theme.typography.titleLarge.copyWith(
                      color: colors.foreground,
                    ),
                  ),
                  SizedBox(width: theme.spacing.md),
                  const MonoBadge(
                    variant: MonoBadgeVariant.success,
                    size: MonoBadgeSize.sm,
                    dot: true,
                    child: Text('On disk'),
                  ),
                ],
              ),
              SizedBox(height: theme.spacing.xl),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: LensStat(
                      label: 'Dimensions',
                      value: '${media.width} x ${media.height}',
                    ),
                  ),
                  Expanded(
                    child: LensStat(
                      label: 'Size',
                      value: _bytes(media.byteSize),
                    ),
                  ),
                  Expanded(
                    child: media is CapturedVideo
                        ? LensStat(
                            label: 'Duration',
                            value: _seconds(media.duration),
                          )
                        : LensStat(
                            label: 'Type',
                            value: media.contentType.split('/').last,
                          ),
                  ),
                ],
              ),
              SizedBox(height: theme.spacing.xl),
              // The cache directory, which the OS may evict — so a real app
              // copies anything that has to outlive the session.
              Text(
                media.path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.code.copyWith(
                  color: colors.foregroundSubtle,
                  fontSize: 11,
                ),
              ),
              SizedBox(height: theme.spacing.xl),
              SizedBox(
                width: double.infinity,
                child: MonoButton(
                  size: MonoButtonSize.lg,
                  onPressed: () =>
                      Navigator.of(context).popUntil((route) => route.isFirst),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
