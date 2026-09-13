import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:url_launcher/url_launcher.dart';

import 'consent_iq.dart';
import 'log.dart';
import 'models.dart';
import 'provider.dart';

const Color defaultPrimaryColor = Color(0xFFF97316);

/// Appends `lang` to an absolute http(s) URL, keeping any fragment. Returns
/// null for anything else so the link is skipped rather than broken.
Uri? noticeUriWithLanguage(String? url, String language) {
  if (url == null) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
    return null;
  }
  final hashIndex = url.indexOf('#');
  final base = hashIndex == -1 ? url : url.substring(0, hashIndex);
  final fragment = hashIndex == -1 ? '' : url.substring(hashIndex);
  final separator = base.contains('?') ? '&' : '?';
  return Uri.tryParse(
    '$base${separator}lang=${Uri.encodeQueryComponent(language)}$fragment',
  );
}

Color parseHexColor(String? hex, [Color fallback = defaultPrimaryColor]) {
  if (hex == null) return fallback;
  var value = hex.trim();
  if (value.startsWith('#')) value = value.substring(1);
  if (value.length == 3) {
    value = value.split('').map((c) => '$c$c').join();
  }
  if (value.length != 6) return fallback;
  final parsed = int.tryParse(value, radix: 16);
  return parsed == null ? fallback : Color(0xFF000000 | parsed);
}

/// Route changes are illegal mid-frame, so defer them when a frame is building.
void runOutsideBuild(VoidCallback action) {
  final phase = SchedulerBinding.instance.schedulerPhase;
  if (phase == SchedulerPhase.idle ||
      phase == SchedulerPhase.postFrameCallbacks) {
    action();
  } else {
    SchedulerBinding.instance.addPostFrameCallback((_) => action());
  }
}

/// Presents the consent sheet whenever `isSheetVisible` is true. Place it
/// anywhere below a [ConsentIQProvider] and a [Navigator]; it renders
/// [child], or nothing when no child is given.
class ConsentSheet extends StatefulWidget {
  const ConsentSheet({super.key, this.child});

  final Widget? child;

  @override
  State<ConsentSheet> createState() => _ConsentSheetState();
}

class _ConsentSheetState extends State<ConsentSheet> {
  ConsentIQ? _consentIQ;
  bool _presented = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next =
        context.getInheritedWidgetOfExactType<ConsentIQProvider>()?.notifier;
    assert(next != null, 'ConsentSheet must be below a ConsentIQProvider.');
    if (!identical(next, _consentIQ)) {
      _consentIQ?.removeListener(_sync);
      _consentIQ = next;
      next?.addListener(_sync);
    }
    _sync();
  }

  @override
  void dispose() {
    _consentIQ?.removeListener(_sync);
    super.dispose();
  }

  void _sync() => runOutsideBuild(_apply);

  void _apply() {
    if (!mounted) return;
    final consentIQ = _consentIQ;
    if (consentIQ == null) return;
    if (consentIQ.isSheetVisible && consentIQ.config != null && !_presented) {
      _present(consentIQ);
    }
  }

  Future<void> _present(ConsentIQ consentIQ) async {
    _presented = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => _ConsentSheetBody(consentIQ: consentIQ),
      );
    } on FlutterError catch (e) {
      _presented = false;
      debugPrint('$logPrefix Could not present the consent sheet: $e');
      return;
    }
    _presented = false;
    // The route closed on its own (swipe, back button, barrier tap): the
    // visitor backed out. A programmatic close already cleared the flag.
    if (consentIQ.isSheetVisible) consentIQ.dismissSheet();
  }

  @override
  Widget build(BuildContext context) => widget.child ?? const SizedBox.shrink();
}

class _ConsentSheetBody extends StatefulWidget {
  const _ConsentSheetBody({required this.consentIQ});

  final ConsentIQ consentIQ;

  @override
  State<_ConsentSheetBody> createState() => _ConsentSheetBodyState();
}

class _ConsentSheetBodyState extends State<_ConsentSheetBody> {
  bool _showCategories = false;
  bool _popped = false;
  late Map<String, bool> _pending;
  ModalRoute<Object?>? _route;
  NavigatorState? _navigator;

  @override
  void initState() {
    super.initState();
    _pending = _initialSelection();
    widget.consentIQ.addListener(_onChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _navigator = Navigator.of(context);
    _onChange();
  }

  @override
  void dispose() {
    widget.consentIQ.removeListener(_onChange);
    super.dispose();
  }

  Map<String, bool> _initialSelection() {
    final consent = widget.consentIQ.consent;
    return {
      for (final category in _categories)
        category.code: category.isRequired ||
            (consent[category.code] ?? category.defaultState),
    };
  }

  List<CategoryInfo> get _categories =>
      (widget.consentIQ.config?.categories ?? const [])
          .where((c) => c.enabled)
          .toList(growable: false);

  void _onChange() {
    if (!mounted || _popped || widget.consentIQ.isSheetVisible) return;
    final route = _route;
    final navigator = _navigator;
    if (route == null || navigator == null) return;
    _popped = true;
    runOutsideBuild(() {
      if (!route.isActive) return;
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    });
  }

  Future<void> _openNotice(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('$logPrefix Could not open the cookie notice: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final consentIQ = widget.consentIQ;
    final config = consentIQ.config;
    if (config == null) return const SizedBox.shrink();

    final language = consentIQ.language;
    final labels = config.labelsFor(language);
    final translations = config.translationsFor(language);
    final blurb = translations?.bannerDescription;
    final noticeUri = noticeUriWithLanguage(config.banner.noticeUrl, language);
    final primary = parseHexColor(config.banner.primaryColor);
    final radius = config.banner.cornerStyle == 'square' ? 4.0 : 12.0;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
    );
    final theme = Theme.of(context);
    final scheme = theme.colorScheme.copyWith(
      primary: primary,
      onPrimary: Colors.white,
    );

    return Directionality(
      textDirection:
          config.isRtl(language) ? TextDirection.rtl : TextDirection.ltr,
      child: Theme(
        data: theme.copyWith(
          colorScheme: scheme,
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: primary,
              foregroundColor: Colors.white,
              shape: shape,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.onSurface,
              shape: shape,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(foregroundColor: primary),
          ),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  labels.title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (blurb != null && blurb.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    blurb,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (noticeUri != null) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: InkWell(
                      onTap: () => _openNotice(noticeUri),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          labels.viewNotice,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: primary,
                            fontWeight: FontWeight.w500,
                            decoration: TextDecoration.underline,
                            decorationColor: primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                if (!_showCategories) ...[
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: consentIQ.acceptAll,
                          child: Text(labels.acceptAll),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: consentIQ.rejectAll,
                          child: Text(labels.reject),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: () => setState(() => _showCategories = true),
                    child: Text(labels.customize),
                  ),
                ] else ...[
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final category in _categories)
                          _CategoryRow(
                            category: category,
                            translation:
                                translations?.categories[category.code],
                            value: category.isRequired
                                ? true
                                : (_pending[category.code] ??
                                    category.defaultState),
                            onChanged: category.isRequired
                                ? null
                                : (value) => setState(
                                      () => _pending[category.code] = value,
                                    ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => consentIQ.savePreferences({
                      ...consentIQ.consent,
                      ..._pending,
                    }),
                    child: Text(labels.save),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.translation,
    required this.value,
    required this.onChanged,
  });

  final CategoryInfo category;
  final CategoryTranslation? translation;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final title = translation?.title.isNotEmpty == true
        ? translation!.title
        : category.name;
    final description = translation?.description.isNotEmpty == true
        ? translation!.description
        : category.description;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle:
          description == null || description.isEmpty ? null : Text(description),
      value: value,
      onChanged: onChanged,
    );
  }
}
