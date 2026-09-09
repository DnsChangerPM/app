import 'package:flutter/material.dart';

import '../models/dns_server.dart';
import '../services/dns_speed_test_service.dart';

class ServerCard extends StatefulWidget {
  final DnsServer server;
  final bool selected;
  final bool locked;
  final VoidCallback? onTap;
  final ValueChanged<int?>? onPingUpdated;

  const ServerCard({
    super.key,
    required this.server,
    required this.selected,
    this.locked = false,
    this.onTap,
    this.onPingUpdated,
  });

  @override
  State<ServerCard> createState() => _ServerCardState();
}

class _ServerCardState extends State<ServerCard> {
  bool _testingPing = false;
  int? _ping;

  @override
  void initState() {
    super.initState();
    _ping = widget.server.pingMs ?? DnsSpeedTestService.instance.cachedPings[widget.server.id];
  }

  @override
  void didUpdateWidget(ServerCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.server.pingMs != oldWidget.server.pingMs) {
      _ping = widget.server.pingMs;
    }
  }

  Future<void> _testPing() async {
    if (_testingPing || widget.locked) return;
    setState(() => _testingPing = true);
    final result = await DnsSpeedTestService.instance.pingServer(widget.server);
    if (mounted) {
      setState(() {
        _testingPing = false;
        _ping = result;
      });
      widget.onPingUpdated?.call(result);
    }
  }

  Color _pingColor(int ping) {
    if (ping < 60) return const Color(0xFF00D1B2);
    if (ping < 130) return const Color(0xFF3AA6FF);
    if (ping < 250) return const Color(0xFFFFC107);
    return const Color(0xFFFF5C5C);
  }

  @override
  Widget build(BuildContext context) {
    final server = widget.server;
    final selected = widget.selected;
    final locked = widget.locked;

    return Opacity(
      opacity: locked ? 0.55 : 1,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        color: selected ? const Color(0xFF13263F) : const Color(0xFF111B2E),
        elevation: selected ? 3 : 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: selected
              ? const BorderSide(color: Color(0xFF3AA6FF), width: 1.8)
              : BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: (selected
                            ? const Color(0xFF3AA6FF)
                            : const Color(0xFF1C2A44))
                        .withOpacity(0.25),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: selected
                          ? const Color(0xFF3AA6FF).withOpacity(0.5)
                          : Colors.white.withOpacity(0.05),
                    ),
                  ),
                  child: Icon(
                    locked
                        ? Icons.lock_outline
                        : server.isCustom
                            ? Icons.tune
                            : server.category == DnsCategory.gaming
                                ? Icons.sports_esports_outlined
                                : server.category == DnsCategory.security
                                    ? Icons.security_outlined
                                    : server.category == DnsCategory.family
                                        ? Icons.family_restroom_outlined
                                        : Icons.dns_outlined,
                    color: selected ? const Color(0xFF3AA6FF) : Colors.white70,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              server.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (locked) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color:
                                    const Color(0xFFFFC107).withOpacity(0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'LOCKED',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFFFFC107)),
                              ),
                            ),
                          ],
                          if (server.isPremium && !locked) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.workspace_premium,
                                size: 16, color: Color(0xFF00D1B2)),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        server.description,
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 12.5),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.06),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              server.isPremium
                                  ? 'Private subscription DNS'
                                  : server.addresses.take(2).join('  •  '),
                              textDirection: TextDirection.ltr,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 11),
                            ),
                          ),
                          if (server.addresses.any((a) => a.contains(':')))
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: const Color(0xFF3AA6FF).withOpacity(0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'IPv6',
                                style: TextStyle(
                                    color: Color(0xFF3AA6FF),
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (!locked)
                      InkWell(
                        onTap: _testingPing ? null : _testPing,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: _ping != null
                                ? _pingColor(_ping!).withOpacity(0.12)
                                : Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: _ping != null
                                  ? _pingColor(_ping!).withOpacity(0.3)
                                  : Colors.white.withOpacity(0.08),
                            ),
                          ),
                          child: _testingPing
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white70),
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_ping != null) ...[
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: _pingColor(_ping!),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '$_ping ms',
                                        style: TextStyle(
                                          color: _pingColor(_ping!),
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                    ] else ...[
                                      const Icon(Icons.speed,
                                          size: 13, color: Colors.white54),
                                      const SizedBox(width: 3),
                                      const Text(
                                        'پینگ',
                                        style: TextStyle(
                                            color: Colors.white54,
                                            fontSize: 11),
                                      ),
                                    ],
                                  ],
                                ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    if (selected)
                      const Icon(Icons.check_circle,
                          color: Color(0xFF3AA6FF), size: 22)
                    else if (locked)
                      const Icon(Icons.chevron_right,
                          color: Colors.white38, size: 20)
                    else
                      const Icon(Icons.radio_button_unchecked,
                          color: Colors.white24, size: 20),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
