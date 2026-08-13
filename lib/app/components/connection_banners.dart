import 'dart:async';
import 'dart:ui';

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
  const ConnectionBanners({super.key, this.showIMessage = true, this.topInset = 0});

  /// Whether the iMessage bar is relevant here. False inside SMS-only threads:
  /// the BlueBubbles server being down changes nothing for them.
  final bool showIMessage;

  /// Extra height for the first bar, so its frosted background reaches up behind
  /// the status bar. Only needed where nothing above has already absorbed that
  /// inset (the iOS chat list draws behind it; a Scaffold app bar does not).
  final double topInset;

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
      final bars = <Widget>[];

      if (!_online) {
        bars.add(const _Banner(text: "No internet connection", warning: true));
      } else {
        if (widget.showIMessage && _socketDown) {
          bars.add(const _Banner(text: "iMessage server offline"));
        }
        if (SmsSvc.serverOnline.value == false) {
          bars.add(const _Banner(text: "SMS server offline", warning: true));
        }
      }

      if (bars.isNotEmpty && widget.topInset > 0) {
        final first = bars.first as _Banner;
        bars[0] = _Banner(text: first.text, warning: first.warning, topInset: widget.topInset);
      }

      return AnimatedSize(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        alignment: Alignment.topCenter,
        child: bars.isEmpty
            ? const SizedBox(width: double.infinity)
            : Column(mainAxisSize: MainAxisSize.min, children: bars),
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
