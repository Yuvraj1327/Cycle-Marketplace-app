import '../../core/utils/json.dart';

class Ticket {
  const Ticket({
    required this.id,
    required this.number,
    required this.type,
    required this.subject,
    required this.description,
    required this.status,
    this.resolution,
    this.createdAt,
  });
  final String id, number, type, subject, description, status;
  final String? resolution;
  final DateTime? createdAt;
  factory Ticket.fromJson(Map<String, dynamic> j) => Ticket(
    id: j['id'] as String,
    number: j['ticket_number'] as String,
    type: j['type'] as String,
    subject: j['subject'] as String,
    description: j['description'] as String,
    status: j['status'] as String,
    resolution: asStringOrNull(j['resolution']),
    createdAt: asDate(j['created_at']),
  );
}
