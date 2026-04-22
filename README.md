# Foto con Regola dei Terzi

App Flutter che analizza la tua galleria e trova automaticamente le foto che rispettano la regola dei terzi. Tutto 100% on-device: nessuna foto esce dal telefono.

### Cosa fa
Scansiona le foto, rileva il soggetto principale — volto, fiore, animale, pianta, cibo, veicolo o soggetto generico — e verifica se è posizionato sui punti di forza o lungo le linee dei terzi. Le foto che passano le esporta in un album dedicato chiamato “Regola dei Terzi”.

### Funzioni principali
- **7 tipi di soggetto**: Volto, Fiore, Animale, Pianta, Cibo, Veicolo, Soggetto principale
- **Filtri impatto**: scegli album, max foto, min megapixel, solo da una certa data
- **Tolleranza regolabile**: da 5% a 25% per essere più o meno severo
- **Controllo batteria**: si ferma da solo sotto la soglia che imposti, default 20%
- **Grafico performance live**: vedi foto/s in tempo reale per capire se il telefono rallenta
- **Test campione**: “Testa 10 foto” stima tempo totale e consumo batteria prima di partire
- **Persistenza**: salva risultati e impostazioni. Se chiudi l’app, riapri e trovi tutto
- **Export intelligente**: copia in album + Sync che aggiunge/rimuove solo il necessario
- **Log CSV**: esporta `timestamp, fps, avg_mlkit_ms, batteria, filtri...` per analizzare le performance
- **Overlay griglia**: tap su una foto per vedere griglia, punti di forza e box del soggetto

### Permessi richiesti
- **Lettura galleria**: per scansionare le foto
- **Scrittura galleria**: per creare l’album “Regola dei Terzi” e copiare le foto
- **Stato batteria**: per il controllo batteria opzionale

### Installazione dev
1. **Prerequisiti**: Flutter 3.19+, Android Studio o Xcode
2. **Clona e installa**
   ```bash
   git clone <repo>
   cd regola_terzi
   flutter pub get
