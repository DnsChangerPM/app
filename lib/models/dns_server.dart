/// A single DNS upstream, either a public/free server or a licensed server.
class DnsServer {
  final String id;
  final String name;
  final String description;
  final List<String> addresses; // IPs (optionally "ip:port"), no DoH URLs.
  final String? country;
  final bool isPremium;

  const DnsServer({
    required this.id,
    required this.name,
    required this.description,
    required this.addresses,
    this.country,
    this.isPremium = false,
  });

  DnsServer copyWith({bool? isPremium}) {
    return DnsServer(
      id: id,
      name: name,
      description: description,
      addresses: addresses,
      country: country,
      isPremium: isPremium ?? this.isPremium,
    );
  }
}
