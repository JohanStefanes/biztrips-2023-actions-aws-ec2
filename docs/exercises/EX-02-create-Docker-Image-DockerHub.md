# EX-02 – Docker-Image bauen, taggen und auf Docker Hub veröffentlichen

## Lernziele

Nach dieser Übung könnt ihr:

- ein Multi-Stage-`Dockerfile` für eine React/Vite-App schreiben
- ein Docker-Image lokal bauen und mit einer sinnvollen Tagging-Strategie versehen (`prod01`, `latest`, Git-Kurz-SHA)
- ein Docker-Hub-Repository anlegen und euch per CLI dort anmelden
- ein Image auf Docker Hub pushen und wieder herunterladen
- den Container lokal starten und testen

> **Startpunkt:** Schritte 1–8 (lokaler Docker-Workflow) sind unabhängig vom Stand der Pipeline. Für Schritt 9 (Integration als `docker`-Job) vom Tag [`v1-start`](https://github.com/bbwlc/biztrips-2023-actions-aws-ec2/releases/tag/v1-start) ausgehen — dort fehlt der `docker`-Job noch. Die fertige Referenzlösung mit `docker`-Job entspricht dem Tag [`v1-solution`](https://github.com/bbwlc/biztrips-2023-actions-aws-ec2/releases/tag/v1-solution) bzw. dem aktuellen Stand von `main`.

## Voraussetzungen

- Docker Desktop (oder Docker Engine) lokal installiert und gestartet: `docker --version`
- Ein kostenloser [Docker Hub](https://hub.docker.com/)-Account
- Das Repository aus [EX-01](./EX-01-deploy-AWS-EC2.md) lokal ausgecheckt
- Node.js ≥ 24 lokal installiert (nur zur Kontrolle, der Build läuft später im Container)

---

## Schritt 1: `.dockerignore` anlegen

Damit unnötige oder sensible Dateien nicht in den Build-Kontext gelangen, im Projektroot eine Datei `.dockerignore` anlegen:

```
node_modules
dist
build
.git
.env
.env.local
*.log
```

> Ohne `.dockerignore` würde z. B. `node_modules` mit in den Build-Kontext kopiert — das macht den Build unnötig langsam und kann alte, lokale Artefakte in den Container schleusen.

---

## Schritt 2: Multi-Stage-`Dockerfile` schreiben

Im Projektroot eine Datei `Dockerfile` anlegen:

```dockerfile
# --- Stage 1: Build ---
FROM node:24-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
ARG VITE_API_BASE_URL
ARG VITE_IMGS=items
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
ENV VITE_IMGS=$VITE_IMGS
RUN npm run build

# --- Stage 2: Runtime ---
FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

Warum zwei Stages?

- **Stage 1 (`build`)** enthält Node, `node_modules` und den kompletten Quellcode — das brauchen wir nur, um `dist/` zu erzeugen.
- **Stage 2 (`nginx`)** enthält am Ende **nur** die fertigen, statischen Dateien plus einen schlanken nginx. Node, `node_modules` und der Quellcode landen nicht im finalen Image — das macht es deutlich kleiner und reduziert die Angriffsfläche.

`VITE_API_BASE_URL`/`VITE_IMGS` werden hier bewusst als `ARG` (Build-Zeit) übergeben, genau wie in der GitHub-Actions-Pipeline aus EX-01 (`vars.VITE_API_BASE_URL`) — Vite kompiliert diese Werte fest in das JS-Bundle ein, sie können nicht mehr nachträglich zur Laufzeit im Container geändert werden.

---

## Schritt 3: `nginx.conf` für SPA-Routing anlegen

React Router (bzw. Client-Side-Routing generell) braucht einen Fallback auf `index.html`, sonst gibt es bei einem Reload auf einer Unterseite ein 404. Im Projektroot `nginx.conf`:

```nginx
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

Das ist dieselbe Konfiguration, die in EX-01 direkt auf der EC2-Instanz unter `/etc/nginx/sites-available/biztrips` liegt — nur läuft nginx diesmal *im Container* statt direkt auf dem Host.

---

## Schritt 4: Image lokal bauen und taggen

Docker-Hub-Nutzernamen als Variable setzen (Beispiel: `bbwlc`):

```bash
export DOCKERHUB_USER=bbwlc
```

Image bauen und dabei mehrere Tags gleichzeitig vergeben:

```bash
docker build \
  --build-arg VITE_API_BASE_URL="http://ec2-3-93-182-80.compute-1.amazonaws.com:3001/" \
  -t "$DOCKERHUB_USER/biztrips:prod01" \
  -t "$DOCKERHUB_USER/biztrips:latest" \
  -t "$DOCKERHUB_USER/biztrips:$(git rev-parse --short HEAD)" \
  .
```

### Tagging-Strategie

| Tag | Zweck |
| --- | --- |
| `prod01` | fester Bezeichner für "das, was aktuell auf Produktionsserver 01 läuft" — wird bei jedem Deploy auf dieses Image umgebogen |
| `latest` | letzter erfolgreicher Build, nicht zwingend deployed |
| `<git-sha>` (z. B. `a1b2c3d`) | unveränderliche, exakt einem Commit zuordenbare Version — wichtig für Rollbacks und Nachvollziehbarkeit |

`latest` allein reicht in der Praxis **nicht**, da es sich bei jedem Push verschiebt und man später nicht mehr weiß, welcher Commit tatsächlich lief. Deshalb immer zusätzlich mit einer unveränderlichen Referenz (Git-SHA) taggen.

---

## Schritt 5: Image lokal testen

```bash
docker run --rm -p 8080:80 "$DOCKERHUB_USER/biztrips:prod01"
```

Im Browser `http://localhost:8080` öffnen und prüfen, ob die App korrekt lädt. Mit `Ctrl+C` beenden.

---

## Schritt 6: Bei Docker Hub anmelden

```bash
docker login -u "$DOCKERHUB_USER"
```

Fragt nach einem Passwort oder — empfohlen — einem [Access Token](https://hub.docker.com/settings/security) statt des echten Account-Passworts.

> Docker-Hub-Repository muss vorher nicht manuell angelegt werden: Bei `docker push` auf ein privates Konto wird ein öffentliches Repository automatisch erstellt, sofern der Name noch frei ist. Für ein **privates** Repository legt es vorher explizit unter *Docker Hub → Create Repository* an.

---

## Schritt 7: Image pushen

```bash
docker push "$DOCKERHUB_USER/biztrips:prod01"
docker push "$DOCKERHUB_USER/biztrips:latest"
docker push "$DOCKERHUB_USER/biztrips:$(git rev-parse --short HEAD)"
```

Kontrolle im Browser unter `https://hub.docker.com/r/<user>/biztrips/tags`.

---

## Schritt 8: Image auf einem anderen Rechner testen (optional)

Um zu prüfen, dass wirklich alles im Image steckt und nichts aus dem lokalen Dateisystem "durchgeschummelt" wurde, lokales Image löschen und frisch von Docker Hub ziehen:

```bash
docker rmi "$DOCKERHUB_USER/biztrips:prod01"
docker run --rm -p 8080:80 "$DOCKERHUB_USER/biztrips:prod01"
```

Läuft die App weiterhin fehlerfrei, wurde nichts vergessen.

---

## Bekannte Stolpersteine

**`denied: requested access to the resource is denied` beim `docker push`**
Entweder seid ihr nicht eingeloggt (`docker login`) oder der Image-Name stimmt nicht mit eurem Docker-Hub-Nutzernamen überein. Der Teil vor dem `/` im Tag (`$DOCKERHUB_USER/biztrips`) **muss** exakt eurem Docker-Hub-Benutzernamen (oder einer Organisation, in der ihr Schreibrechte habt) entsprechen.

**App im Container zeigt eine falsche/leere API-Basis-URL**
`VITE_API_BASE_URL` wird beim `docker build` fest in den JS-Bundle einkompiliert (siehe Schritt 2). Ein `docker run -e VITE_API_BASE_URL=...` hat **keinen** Effekt mehr — das Image muss mit dem korrekten `--build-arg` neu gebaut werden.

**404 nach Browser-Reload auf einer Unterseite**
`nginx.conf` fehlt oder wurde nicht korrekt ins Image kopiert (Schritt 3) — ohne `try_files ... /index.html` kennt nginx nur die Route `/`, aber keine Client-Side-Routen.

**Build-Fehler `npm ci` wegen fehlender `package-lock.json`**
`package-lock.json` muss mit ins Repository eingecheckt und im `COPY`-Befehl des Dockerfiles referenziert sein (Schritt 2) — ohne Lockfile schlägt `npm ci` bewusst fehl (im Gegensatz zu `npm install`).

---

## Schritt 9: Als GitHub-Actions-Job integrieren (im Repo bereits umgesetzt)

Die Schritte 1–7 lassen sich vollständig automatisieren: nach jedem erfolgreichen Deploy auf `main` soll die Pipeline automatisch ein Image bauen, taggen und auf Docker Hub pushen. Dieses Repository enthält die fertige Referenzlösung — schaut euch `Dockerfile`, `.dockerignore`, `nginx.conf` und den `docker`-Job in `.github/workflows/deploy.yml` an, bevor ihr eure eigene Lösung damit vergleicht.

### Neuer Job `docker` in `deploy.yml`

```yaml
  docker:
    name: Docker-Image bauen und auf Docker Hub veröffentlichen
    runs-on: ubuntu-latest
    needs: deploy
    if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
    steps:
      - uses: actions/checkout@v4

      - name: Bei Docker Hub anmelden
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Buildx einrichten
        uses: docker/setup-buildx-action@v3

      - name: Image bauen und pushen
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          build-args: |
            VITE_API_BASE_URL=${{ vars.VITE_API_BASE_URL }}
            VITE_IMGS=${{ vars.VITE_IMGS || 'items' }}
          tags: |
            ${{ secrets.DOCKERHUB_USERNAME }}/biztrips:prod01
            ${{ secrets.DOCKERHUB_USERNAME }}/biztrips:latest
            ${{ secrets.DOCKERHUB_USERNAME }}/biztrips:${{ github.sha }}
```

Wichtige Design-Entscheidungen:

- **`needs: deploy`** — der Docker-Job läuft erst, nachdem der EC2-Deploy erfolgreich war. Ein grünes Docker-Image bedeutet damit auch "das lief bereits erfolgreich auf Produktion".
- **Wiederverwendete `vars`** — `VITE_API_BASE_URL`/`VITE_IMGS` sind dieselben Repository-Variables, die auch der `build`-Job aus EX-01 schon nutzt. Keine neue Konfiguration nötig.
- **`github.sha`** statt der lokal in Schritt 4 verwendeten Kurzform (`git rev-parse --short HEAD`) — in Actions ist der volle Commit-SHA direkt als Kontextvariable verfügbar und eindeutig; ein manueller `git`-Aufruf ist nicht nötig.
- **`docker/build-push-action`** statt einzelner `docker build`/`docker push`-Befehle — nutzt automatisch den von `docker/setup-buildx-action` eingerichteten BuildKit-Builder inkl. Layer-Caching und unterstützt Multi-Tag-Pushes in einem Schritt.

### Benötigte zusätzliche GitHub Secrets

Unter *Settings → Secrets and variables → Actions → Secrets* (Repository-Ebene, kein Environment nötig, da hier nicht auf die EC2-Instanz zugegriffen wird):

| Secret | Beispiel | Beschreibung |
| --- | --- | --- |
| `DOCKERHUB_USERNAME` | `bbwlc` | Docker-Hub-Benutzername |
| `DOCKERHUB_TOKEN` | (Access Token) | Unter *Docker Hub → Account Settings → Security → New Access Token* erzeugen — **nicht** das Account-Passwort verwenden |

Per CLI setzen:

```bash
gh secret set DOCKERHUB_USERNAME --body "<dein-dockerhub-user>"
gh secret set DOCKERHUB_TOKEN --body "<dein-access-token>"
```

### Ergebnis prüfen

```bash
gh run view --job=<docker-job-id> --log
```

oder direkt unter `https://hub.docker.com/r/<dockerhub-user>/biztrips/tags` nachsehen, ob `prod01`, `latest` und der Commit-SHA-Tag mit aktuellem Zeitstempel erschienen sind.

---

## Reflexionsfragen

1. Warum ist das finale Image (Stage 2) deutlich kleiner als es wäre, wenn man alles in einem einzigen `FROM node:24-alpine` bauen und dort auch laufen lassen würde?
2. Warum reicht der Tag `latest` allein nicht aus, um zuverlässig nachzuvollziehen, welcher Commit gerade auf `prod01` läuft?
3. Warum müssen `VITE_API_BASE_URL`/`VITE_IMGS` als `ARG` beim `docker build` und nicht als `-e`-Umgebungsvariable beim `docker run` gesetzt werden?
4. Was ist der Unterschied zwischen dem Deployment-Ansatz aus EX-01 (statische Dateien per `rsync` direkt auf eine EC2-Instanz mit installiertem nginx) und diesem Docker-basierten Ansatz? Welche Vor- und Nachteile hat Docker hier?
