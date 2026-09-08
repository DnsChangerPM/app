import '../models/dns_server.dart';

/// Built-in free/public DNS servers (IPv4 first, IPv6 second where available).
const List<DnsServer> freeDnsServers = [
  DnsServer(
    id: 'cloudflare',
    name: 'Cloudflare',
    description: 'Fast and privacy friendly. 1.1.1.1',
    addresses: ['1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001'],
    country: 'Global',
  ),
  DnsServer(
    id: 'google',
    name: 'Google',
    description: 'Reliable public DNS. 8.8.8.8',
    addresses: ['8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844'],
    country: 'Global',
  ),
  DnsServer(
    id: 'quad9',
    name: 'Quad9',
    description: 'Blocks malicious domains. 9.9.9.9',
    addresses: ['9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9'],
    country: 'Global',
  ),
  DnsServer(
    id: 'opendns',
    name: 'OpenDNS',
    description: 'Cisco OpenDNS. 208.67.222.222',
    addresses: ['208.67.222.222', '208.67.220.220'],
    country: 'Global',
  ),
  DnsServer(
    id: 'adguard',
    name: 'AdGuard DNS',
    description: 'Blocks ads and trackers. 94.140.14.14',
    addresses: ['94.140.14.14', '94.140.15.15', '2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff'],
    country: 'Global',
  ),
  DnsServer(
    id: 'shecan',
    name: 'Shecan',
    description: 'Iranian DNS, good for local services. 178.22.122.100',
    addresses: ['178.22.122.100', '185.51.200.2'],
    country: 'IR',
  ),
  DnsServer(
    id: 'electro',
    name: 'Electro',
    description: 'Iranian DNS. 78.157.42.100',
    addresses: ['78.157.42.100', '78.157.42.101'],
    country: 'IR',
  ),
  DnsServer(
    id: 'radar',
    name: 'Radar Game',
    description: 'Popular gaming DNS. 10.202.10.10',
    addresses: ['10.202.10.10', '10.202.10.11'],
    country: 'IR',
  ),
  DnsServer(
    id: 'begzar',
    name: 'Begzar',
    description: 'Iranian DNS. 185.55.226.26',
    addresses: ['185.55.226.26', '185.55.225.25'],
    country: 'IR',
  ),
  DnsServer(
    id: '403',
    name: '403.online',
    description: 'Iranian DNS. 10.202.10.202',
    addresses: ['10.202.10.202', '10.202.10.102'],
    country: 'IR',
  ),
];
