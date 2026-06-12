Konzept: Event-Streaming Interface (EventStream)1. Architektur & AbstraktionsmodellDa die zugrundeliegenden Broker unterschiedlich funktionieren, führen wir eine gemeinsame semantische Schicht ein:Producer/Publisher: Sendet Events an ein logisches Ziel.Consumer/Subscriber: Abonniert Events von einem logischen Ziel.Channel/Stream: Die Abstraktion für ein Kafka-Topic oder eine RabbitMQ-Queue/Exchange.Event: Die payload (Nutzdaten) inklusive Metadaten (Header, Routing-Keys).Das Paradigmen-MappingUnser Interface vereinheitlicht die Konzepte wie folgt:KonzeptLog-basiert (z. B. Apache Kafka)Queue-basiert (z. B. RabbitMQ)Logisches ZielTopicExchange + QueueSkalierungPartitionen innerhalb eines TopicsConsumer-Gruppen an einer QueueDaten-EigenschaftPersistent (Append-Only Log), replayableEphemer (Nachricht wird nach ACK gelöscht)2. Interface-Definition (API-Design)Das Interface wird bewusst minimalistisch und asynchron gehalten, um maximale Performance zu gewährleisten.A. Das Kern-Interface (EventStream)Jeder Broker-Treiber (Plugin) muss dieses Interface implementieren.TypeScriptinterface EventStream {
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  
  createProducer(channel: string): Promise<Producer>;
  createConsumer(channel: string, options: ConsumerOptions): Promise<Consumer>;
}
B. Producer InterfaceZuständig für das Senden von Nachrichten.TypeScriptinterface Producer {
  send(event: CloudEvent): Promise<void>;
}
C. Consumer InterfaceZuständig für das Empfangen und Bestätigen von Nachrichten.TypeScriptinterface Consumer {
  subscribe(handler: (event: CloudEvent) => Promise<void>): Promise<void>;
  commit(event: CloudEvent): Promise<void>; // Für manuelle Offsets/ACKs
}
3. Daten-Standardisierung: CloudEventsUm zu verhindern, dass Broker-spezifische Header das Interface kompromittieren, nutzen wir den CNCF-Standard CloudEvents für die Payload-Struktur:JSON{
  "specversion" : "1.0",
  "type"        : "com.example.object.deleted",
  "source"      : "/storage/bucket",
  "id"          : "A234-1234-1234",
  "time"        : "2026-06-06T12:00:00Z",
  "datacontenttype" : "application/json",
  "data"        : {
    "bucketId": "images",
    "filename": "profile.jpg"
  }
}
Kafka-Implementierung: data wird zu den Kafka-Bytes, andere Felder werden (wo möglich) in die Kafka-Header gemappt.RabbitMQ-Implementierung: Ähnliches Mapping in die RabbitMQ properties.headers.4. Treiber-Implementierungsstrategie (Die Adapter)Hier wird definiert, wie das Interface die internen Besonderheiten der Broker wegabstrahiert.1. Der Kafka-Adapter (Log-Modell)Skalierung: Nutzt Kafkas natives Consumer Group Modell.Offset-Management: Der commit() Befehl des Consumers triggert das Speichern des Offsets in Kafka.Garantie: At-least-once Delivery standardmäßig.2. Der RabbitMQ-Adapter (AMQP-Modell)Topologie-Setup: Beim Erstellen eines Producers/Consumers sorgt der Adapter im Hintergrund dafür, dass die nötigen Exchanges (z.B. topic-Type) und Queues existieren und korrekt über ein Routing-Key-Muster (channel) gebunden (bind) sind.Acknowledge: Der commit() Befehl führt intern zu einem channel.ack(message).5. Erweiterte Features & Resilienz (Enterprise-Ready)Ein moderner Daten-Stack benötigt Mechanismen für den Fehlerfall. Das Interface sollte folgende Pattern von Haus aus unterstützen:Dead Letter Queue (DLQ): Schlägt die Verarbeitung eines Events mehrfach fehl, fängt das Interface den Fehler ab und schiebt das Event in einen separaten channel.deadletter Stream, statt den Consumer zu blockieren.Backpressure & Prefetch: Einstellbare Limits (ConsumerOptions.prefetchCount), wie viele Nachrichten ein Consumer gleichzeitig puffern und verarbeiten darf, um Out-of-Memory-Fehler zu vermeiden.Idempotenz-Hilfen: Da im verteilten System "At-least-once" der Standard ist, liefert das Consumer-Interface die Event.id standardmäßig mit, damit die Anwendung Duplikate leicht erkennen kann.6. Konfigurations-BeispielDer Entwickler initialisiert den Stack deklarativ über eine Konfiguration:YAMLevent_stream:
  provider: "kafka" # oder "rabbitmq"
  connection_uri: "kafka://localhost:9092"
  options:
    client_id: "analytics-service"
    retries: 3
Dieses Konzept fügt sich nahtlos neben Cassandra und Neo4j ein. Während die Datenbanken für strukturierte Abfragen da sind, fungiert dieses Interface als das Nervensystem, das Datenänderungen in Echtzeit durch den gesamten Stack propagiert.
