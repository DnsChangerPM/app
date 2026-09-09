/// Categories for DNS classification
enum DnsCategory {
  all,
  gaming,
  general,
  security,
  family,
  custom;

  String get labelFa {
    switch (this) {
      case DnsCategory.all:
        return 'همه';
      case DnsCategory.gaming:
        return 'گیمینگ و رفع تحریم';
      case DnsCategory.general:
        return 'پرسرعت و عمومی';
      case DnsCategory.security:
        return 'ضد تبلیغات و امنیت';
      case DnsCategory.family:
        return 'خانواده و کودک';
      case DnsCategory.custom:
        return 'شخصی';
    }
  }

  String get labelEn {
    switch (this) {
      case DnsCategory.all:
        return 'All';
      case DnsCategory.gaming:
        return 'Gaming & Bypass';
      case DnsCategory.general:
        return 'Fast & General';
      case DnsCategory.security:
        return 'AdBlock & Security';
      case DnsCategory.family:
        return 'Family & Safe';
      case DnsCategory.custom:
        return 'Custom';
    }
  }
}

/// A single DNS upstream, either a public/free server or a licensed server.
class DnsServer {
  final String id;
  final String name;
  final String description;
  final List<String> addresses; // IPs (optionally "ip:port"), no DoH URLs.
  final String? country;
  final bool isPremium;
  final bool isCustom;
  final DnsCategory category;
  final List<String> tags;
  final int? pingMs;
  final String? dohUrl;
  final String? dotHost;
  final bool isFavorite;

  const DnsServer({
    required this.id,
    required this.name,
    required this.description,
    required this.addresses,
    this.country,
    this.isPremium = false,
    this.isCustom = false,
    this.category = DnsCategory.general,
    this.tags = const [],
    this.pingMs,
    this.dohUrl,
    this.dotHost,
    this.isFavorite = false,
  });

  DnsServer copyWith({
    String? id,
    String? name,
    String? description,
    List<String>? addresses,
    String? country,
    bool? isPremium,
    bool? isCustom,
    DnsCategory? category,
    List<String>? tags,
    int? pingMs,
    String? dohUrl,
    String? dotHost,
    bool? isFavorite,
  }) {
    return DnsServer(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      addresses: addresses ?? this.addresses,
      country: country ?? this.country,
      isPremium: isPremium ?? this.isPremium,
      isCustom: isCustom ?? this.isCustom,
      category: category ?? this.category,
      tags: tags ?? this.tags,
      pingMs: pingMs ?? this.pingMs,
      dohUrl: dohUrl ?? this.dohUrl,
      dotHost: dotHost ?? this.dotHost,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'addresses': addresses,
        'country': country,
        'isPremium': isPremium,
        'isCustom': isCustom,
        'category': category.name,
        'tags': tags,
        'dohUrl': dohUrl,
        'dotHost': dotHost,
        'isFavorite': isFavorite,
      };

  factory DnsServer.fromJson(Map<String, dynamic> json) {
    DnsCategory cat = DnsCategory.general;
    final catStr = json['category'] as String?;
    if (catStr != null) {
      cat = DnsCategory.values.firstWhere(
        (c) => c.name == catStr,
        orElse: () => (json['isCustom'] == true ? DnsCategory.custom : DnsCategory.general),
      );
    } else if (json['isCustom'] == true) {
      cat = DnsCategory.custom;
    }

    return DnsServer(
      id: json['id'] as String? ?? 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: json['name'] as String? ?? 'Custom DNS',
      description: json['description'] as String? ?? '',
      addresses: (json['addresses'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      country: json['country'] as String?,
      isPremium: json['isPremium'] == true,
      isCustom: json['isCustom'] == true,
      category: cat,
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      dohUrl: json['dohUrl'] as String?,
      dotHost: json['dotHost'] as String?,
      isFavorite: json['isFavorite'] == true,
    );
  }
}
