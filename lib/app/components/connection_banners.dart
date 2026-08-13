import 'dart:async';
import 'dart:ui';

import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/backend/sms/imessage_mode.dart';
import 'package:bluebubbles/services/backend/sms/sms_service.dart';
import 'package:bluebubbles/services/network/socket_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Frosted status bars shown under the top bar when something the app depends on
/// is unreachable.
///
/// Replaces the old 4px red line, which said "something is wrong" without saying
/// what, and appeared on every screen.
///
///  - red    "iMessage server offline"   — the BlueBubbles socket is down. Only
///           where it's actionable: the chat list, and inside threads that can
///           actually use iMessage.
///  - yellow "SMS server offline"        — our sync server isn't answering. SMS
///           still sends over the SIM; only cross-device sync is affected, hence
///           the softer colour.
///  - yellow "No internet connection"    — shown alone, since in that case both
///           servers are unreachable and naming them adds nothing.
class ConnectionBanners extends StatefulWidget {
  const ConnectionBanners({super.key, this.showIMessage = true, this.topInset = 0, this.child});

  /// Whether the iMessage bar is relevant here. False inside SMS-only threads:
  /// the BlueBubbles server being down changes nothing for them.
  final bool showIMessage;

  /// Extra height for the first bar, so its frosted background reaches up behind
  /// the status bar. Only needed where nothing above has already absorbed that
  /// inset (the iOS chat list draws behind it; a Scaffold app bar does not).
  final double topInset;

  /// Optional subtree to place under the bars, pushed down rather than covered.
  ///
  /// Use this to wrap a whole screen whose own header already reserves room for
  /// the status bar (the conversation view). While a bar is showing it has taken
  /// over that space, so the subtree is told the top inset is zero — otherwise
  /// the header pads for a status bar that is no longer there and leaves a gap.
  final Widget? child;

  @override
  State<ConnectionBanners> createState() => _ConnectionBannersState();
}

class _ConnectionBannersState extends State<ConnectionBanners> {
  /// The socket drops briefly all the time (screen off, network handover). Only
  /// call it offline once it has stayed down, so the bar doesn't flicker.
  static const Duration _socketGrace = Duration(seconds: 6);

  bool _online = true;
  bool _socketDown = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Timer? _socketTimer;
  Worker? _socketWorker;

  @override
  void initState() {
    super.initState();
    _checkConnectivity();
    _connectivity = Connectivity().onConnectivityChanged.listen(_onConnectivity);
    _socketWorker = ever(SocketSvc.state, _onSocketState);
    _onSocketState(SocketSvc.state.value);
  }

  Future<void> _checkConnectivity() async {
    try {
      _onConnectivity(await Connectivity().checkConnectivity());
    } catch (_) {
      // Treat an unreadable connectivity state as online: a false "no internet"
      // is worse than no bar at all.
    }
  }

  void _onConnectivity(List<ConnectivityResult> results) {
    final online = results.isNotEmpty && !(results.length == 1 && results.first == ConnectivityResult.none);
    if (mounted && online != _online) setState(() => _online = online);
  }

  void _onSocketState(SocketState state) {
    if (state == SocketState.connected) {
      _socketTimer?.cancel();
      if (mounted && _socketDown) setState(() => _socketDown = false);
      return;
    }
    if (_socketDown || (_socketTimer?.isActive ?? false)) return;
    _socketTimer = Timer(_socketGrace, () {
      if (!mounted) return;
      if (SocketSvc.state.value != SocketState.connected) {
        setState(() => _socketDown = true);
      }
    });
  }

  @override
  void dispose() {
    _connectivity?.cancel();
    _socketWorker?.dispose();
    _socketTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final problems = <({String text, bool warning})>[];

      final bool muteIMessage = SettingsSvc.settings.ignoreIMessageOffline.value;
      final bool muteSms = SettingsSvc.settings.ignoreSmsOffline.value;

      if (!_online) {
        // Only silenced when both warnings are off — otherwise a user who muted
        // one server would lose the one bar that explains why nothing works.
        if (!(muteIMessage && muteSms)) {
          problems.add((text: "No internet connection", warning: true));
        }
      } else {
        // Nothing about the BlueBubbles server is worth reporting when the user
        // has switched that half of the app off.
        if (widget.showIMessage && !muteIMessage && IMessageMode.enabled && _socketDown) {
          problems.add((text: "iMessage server offline", warning: false));
        }
        if (!muteSms && SmsSvc.serverOnline.value == false) {
          problems.add((text: "SMS server offline", warning: true));
        }
      }

      // The first bar absorbs the status bar when nothing above it already has.
      final double inset = widget.topInset > 0
          ? widget.topInset
          : (widget.child != null ? MediaQuery.paddingOf(context).top : 0);

      final bars = AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: problems.isEmpty
            ? const SizedBox(width: double.infinity)
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, p) in problems.indexed)
                    _Banner(text: p.text, warning: p.warning, topInset: i == 0 ? inset : 0),
                ],
              ),
      );

      if (widget.child == null) return bars;

      final media = MediaQuery.of(context);
      return Column(
        children: [
          bars,
          Expanded(
            child: problems.isEmpty
                ? widget.child!
                : MediaQuery(
                    data: media.copyWith(
                      padding: media.padding.copyWith(top: 0),
                      viewPadding: media.viewPadding.copyWith(top: 0),
                    ),
                    child: widget.child!,
                  ),
          ),
        ],
      );
    });
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.warning = false, this.topInset = 0});

  final String text;

  /// Amber rather than red: degraded, not broken.
  final bool warning;

  final double topInset;

  @override
  Widget build(BuildContext context) {
    final Color base = warning ? const Color(0xFFE8A317) : const Color(0xFFD93025);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          width: double.infinity,
          color: base.withValues(alpha: 0.55),
          padding: EdgeInsets.only(top: 5 + topInset, bottom: 5, left: 12, right: 12),
          alignment: Alignment.center,
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: context.theme.textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ) ??
                const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}
