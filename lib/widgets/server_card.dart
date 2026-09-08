import 'package:flutter/material.dart';

import '../models/dns_server.dart';

class ServerCard extends StatelessWidget {
  final DnsServer server;
  final bool selected;
  final bool locked;
  final VoidCallback? onTap;

  const ServerCard({
    super.key,
    required this.server,
    required this.selected,
    this.locked = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: locked ? 0.55 : 1,
      child: Card(
        color: selected ? const Color(0xFF13263F) : const Color(0xFF111B2E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: selected
              ? const BorderSide(color: Color(0xFF3AA6FF), width: 1.5)
              : BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: (selected ? const Color(0xFF3AA6FF) : const Color(0xFF1C2A44))
                        .withOpacity(0.25),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    locked ? Icons.lock_outline : Icons.dns,
                    color: selected ? const Color(0xFF3AA6FF) : Colors.white54,
                  ),
                ),
                const SizedBox(width: 14),
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
                                  fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                          ),
                          if (locked) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFC107).withOpacity(0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'LOCKED',
                                style: TextStyle(fontSize: 10, color: Color(0xFFFFC107)),
                              ),
                            ),
                          ],
                          if (server.isPremium && !locked) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.workspace_premium, size: 16, color: Color(0xFF00D1B2)),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        server.description,
                        style: const TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        server.addresses.join('  •  '),
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (selected)
                  const Icon(Icons.check_circle, color: Color(0xFF3AA6FF))
                else if (locked)
                  const Icon(Icons.chevron_right, color: Colors.white38),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
