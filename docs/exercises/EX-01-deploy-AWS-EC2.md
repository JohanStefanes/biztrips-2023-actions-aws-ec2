# EX-01 – Deployment einer React/Vite-App auf AWS EC2 mit GitHub Actions

## Lernziele

Nach dieser Übung könnt ihr:

- ein bestehendes lokales Git-Repository mit einem leeren GitHub-Repository verbinden und pushen
- eine EC2-Instanz für das Hosting einer statischen Web-App vorbereiten (nginx)
- eine GitHub-Actions-Pipeline mit den Jobs **test → build → deploy** nachvollziehen
- die für den Deploy-Job nötigen **Secrets** und **Variables** in GitHub konfigurieren
- einen Workflow-Run beobachten, Fehler lesen und gezielt beheben

> **Startpunkt:** Für die eigene Übung vom Tag [`v1-start`](https://github.com/bbwlc/biztrips-2023-actions-aws-ec2/releases/tag/v1-start) ausgehen — `deploy.yml` enthält dort nur die Jobs `test` und `build`, der `deploy`-Job fehlt noch. Die hier beschriebene, fertige Pipeline (inkl. `deploy`-Job) entspricht dem Tag [`v1-solution`](https://github.com/bbwlc/biztrips-2023-actions-aws-ec2/releases/tag/v1-solution) bzw. dem aktuellen Stand von `main`.

## Voraussetzungen

- Ein GitHub-Account mit Zugriff (push-Recht) auf das Ziel-Repository
- `git` und die GitHub CLI (`gh`) lokal installiert, `gh auth login` bereits ausgeführt
- Eine laufende AWS-EC2-Instanz (Ubuntu- oder Amazon-Linux-AMI) mit einer `.pem`-Datei zum SSH-Login
- Security Group der Instanz erlaubt eingehenden Traffic auf Port 22 (SSH) und Port 80 (HTTP)
- Node.js ≥ 24 lokal installiert

---

## Schritt 1: Lokales Repository mit GitHub verbinden

Falls noch kein GitHub-Repository existiert, legt zuerst ein **leeres** privates Repository an (kein README, keine `.gitignore` — sonst gibt es beim ersten Push Konflikte).

Prüft den aktuell konfigurierten Remote:

```bash
git remote -v
```

Zeigt er auf das falsche Repo oder verwendet er ein Protokoll, für das ihr keinen Zugriff habt (z. B. SSH ohne hinterlegten Key), setzt ihn neu:

```bash
git remote set-url origin https://github.com/<user>/<repo>.git
```

**Stolperstein „Repository not found“:** Diese Meldung erscheint sowohl bei falscher URL als auch bei fehlender Berechtigung. Prüft mit `gh auth status`, welcher GitHub-Account gerade aktiv ist — bei mehreren angemeldeten Accounts kann es sein, dass der falsche aktiv ist:

```bash
gh auth status
gh auth switch --hostname github.com --user <dein-github-user>
```

Danach pushen und den Tracking-Branch setzen:

```bash
git push -u origin main
```

---

## Schritt 2: Workflow-Datei verstehen

Die Pipeline liegt in `.github/workflows/deploy.yml` und besteht aus drei Jobs:

| Job | Zweck |
| --- | --- |
| `test` | `npm ci` + `npm test` (Vitest) |
| `build` | `npm run build`, Ergebnis aus `dist/` wird als Artefakt hochgeladen |
| `deploy` | lädt das Artefakt, überträgt es per `rsync` über SSH auf die EC2-Instanz und lädt nginx neu |

Wichtige Details im `deploy`-Job:

- `environment: production` — die Secrets für diesen Job werden aus dem GitHub-**Environment** `production` gelesen, nicht aus den allgemeinen Repo-Secrets
- `if: github.ref == 'refs/heads/main' && ...` — der Deploy läuft nur bei einem Push auf `main`, nicht bei Pull Requests
- Der Job schreibt den privaten SSH-Key temporär nach `~/.ssh/deploy_key`, überträgt die Dateien via `rsync`, und entfernt den Key am Ende garantiert wieder (`if: always()`)

Lest euch die Datei einmal komplett durch, bevor ihr weitermacht.

---

## Schritt 3: EC2-Instanz vorbereiten

Einmalig auf der Instanz ausführen (per SSH verbunden):

```bash
sudo apt update
sudo apt install -y nginx rsync
sudo mkdir -p /var/www/biztrips
sudo chown -R "$USER":"$USER" /var/www/biztrips
```

nginx-Konfiguration unter `/etc/nginx/sites-available/biztrips` anlegen:

```nginx
server {
    listen 80;
    server_name _;
    root /var/www/biztrips;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

Aktivieren und neu laden:

```bash
sudo ln -s /etc/nginx/sites-available/biztrips /etc/nginx/sites-enabled/biztrips
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl reload nginx
```

> Der Deploy-Job ruft `sudo` **ohne Passwort** auf. Das funktioniert bei den AWS-Standard-AMIs für `ubuntu` bzw. `ec2-user` bereits ohne weiteres Zutun.

---

## Schritt 4: GitHub Environment anlegen

Unter *Settings → Environments* im Repository ein Environment namens **`production`** anlegen (Name muss exakt mit `environment: production` in der Workflow-Datei übereinstimmen). Ohne dieses Environment schlägt der Deploy-Job sofort fehl.

---

## Schritt 5: Secrets und Variables konfigurieren

Der Deploy-Job braucht drei **Secrets im Environment `production`** (*Settings → Environments → production → Add secret*, oder per CLI):

| Secret | Beispiel | Beschreibung |
| --- | --- | --- |
| `EC2_HOST` | `ec2-3-93-182-80.compute-1.amazonaws.com` | Public DNS oder IP der Instanz |
| `EC2_USER` | `ec2-user` (Amazon Linux) / `ubuntu` (Ubuntu-AMI) | SSH-Benutzer |
| `EC2_SSH_KEY` | Inhalt der `.pem`-Datei, vollständig inkl. `-----BEGIN...-----`/`-----END...-----` | Privater SSH-Key |

Der `build`-Job braucht zusätzlich zwei **Repository-Variables** (*Settings → Secrets and variables → Actions → Variables*), da dieser Job **kein** `environment: production` gesetzt hat und deshalb nicht auf Environment-Secrets/-Variables zugreifen kann:

| Variable | Beispiel |
| --- | --- |
| `VITE_API_BASE_URL` | `http://ec2-3-93-182-80.compute-1.amazonaws.com:3001/` |
| `VITE_IMGS` | `items` (optional, Default ist bereits `items`) |

### Per GitHub CLI setzen

```bash
gh secret set EC2_HOST --env production --body "ec2-3-93-182-80.compute-1.amazonaws.com"
gh secret set EC2_USER --env production --body "ec2-user"
gh secret set EC2_SSH_KEY --env production < /pfad/zu/deiner-datei.pem

gh variable set VITE_API_BASE_URL --body "http://ec2-3-93-182-80.compute-1.amazonaws.com:3001/"
```

> Für `EC2_SSH_KEY` bewusst mit `< datei.pem` (Datei als stdin) statt `--body "$(cat datei.pem)"` arbeiten — so landet der Key-Inhalt nie sichtbar im Terminal-Verlauf oder in der Shell-History.

---

## Schritt 6: Push auslösen und Workflow beobachten

```bash
git push
gh run list --limit 5
gh run view <run-id>
```

Läuft ein Job rot, zeigt euch die genaue Fehlermeldung:

```bash
gh run view <run-id> --log-failed
```

### Bekannte Stolpersteine

**„refusing to allow an OAuth App to create or update workflow `.github/workflows/deploy.yml` without `workflow` scope“**
Der `gh`-Token hat keine Berechtigung, Workflow-Dateien zu pushen. Token-Scope nachträglich erweitern:

```bash
gh auth refresh -h github.com -s workflow
```

Es folgt ein Device-Login-Flow: Code kopieren, `https://github.com/login/device` öffnen, Code eingeben, mit dem richtigen Account bestätigen. Danach `gh auth setup-git` erneut ausführen und pushen.

**Deploy-Job scheitert im Schritt „SSH-Key einrichten“ mit `Process completed with exit code 1`**
Das bedeutet fast immer: eines der drei Secrets (`EC2_HOST`, `EC2_USER`, `EC2_SSH_KEY`) ist leer oder fehlt im Environment `production`. Prüft mit:

```bash
gh secret list --env production
```

und ergänzt die fehlenden Werte wie in Schritt 5 beschrieben.

**Workflow läuft nicht neu, obwohl Secrets jetzt korrekt sind**
Ihr müsst nicht zwingend einen neuen Commit pushen — ein fehlgeschlagener Run lässt sich gezielt wiederholen:

```bash
gh run rerun <run-id> --failed
```

---

## Schritt 7: Ergebnis prüfen

Nach einem grünen Run sollte die App unter `http://<EC2_HOST>` erreichbar sein:

```bash
curl -I http://ec2-3-93-182-80.compute-1.amazonaws.com
```

Erwartet wird ein `HTTP/1.1 200 OK`. Öffnet die Adresse zusätzlich im Browser und prüft, ob die App fehlerfrei lädt.

---

## Reflexionsfragen

1. Warum liegen `EC2_HOST`, `EC2_USER` und `EC2_SSH_KEY` im Environment `production` und nicht als normale Repository-Secrets?
2. Warum braucht der `build`-Job Repository-*Variables* statt Environment-Secrets, obwohl er im selben Workflow läuft wie `deploy`?
3. Was würde passieren, wenn der `deploy`-Job auch bei Pull Requests laufen würde? Warum schützt die Bedingung `if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'` davor?
4. Warum wird der SSH-Key am Ende des Jobs mit `if: always()` wieder gelöscht, statt nur am erfolgreichen Ende?

---

## Musterlösung zu den Reflexionsfragen

> Erst selbst versuchen, dann vergleichen.

**1. Warum liegen `EC2_HOST`, `EC2_USER` und `EC2_SSH_KEY` im Environment `production` und nicht als normale Repository-Secrets?**

Environment-Secrets sind an das Environment gebunden und werden nur Jobs zur Verfügung gestellt, die explizit `environment: production` deklarieren. So kann man zusätzliche Schutzregeln (z. B. Required Reviewers, Wartezeiten, Branch-Einschränkungen) direkt am Environment festmachen, bevor sensible Deploy-Credentials überhaupt gelesen werden dürfen. Bei normalen Repo-Secrets hätte theoretisch jeder Job im Repo (auch versehentlich in einem PR-Workflow) Zugriff darauf.

**2. Warum braucht der `build`-Job Repository-Variables statt Environment-Secrets, obwohl er im selben Workflow läuft wie `deploy`?**

Weil der `build`-Job kein `environment: production` gesetzt hat, hat er schlicht keinen Zugriff auf Environment-Secrets/-Variables — der Zugriff ist strikt an die Deklaration gebunden, nicht daran, in welchem Workflow der Job läuft. `VITE_API_BASE_URL`/`VITE_IMGS` werden zudem zur Build-Zeit in den Vite-Build einkompiliert (kein Geheimnis, sondern eine öffentlich im Frontend-Bundle sichtbare URL), deshalb reichen normale, ungeschützte Repository-Variables völlig aus.

**3. Was würde passieren, wenn der `deploy`-Job auch bei Pull Requests laufen würde? Warum schützt die Bedingung davor?**

Ohne diese Bedingung würde jeder PR — auch von einem Fork oder mit noch ungeprüftem Code — potenziell einen Deploy auf die Produktions-EC2-Instanz auslösen, inklusive Zugriff auf den privaten SSH-Key. Das wäre sowohl ein Sicherheitsrisiko (fremder Code bekäme faktisch Zugriff auf Produktionscredentials) als auch fachlich falsch, da PR-Branches oft nicht "production-ready" sind. Die Bedingung `github.ref == 'refs/heads/main' && github.event_name != 'pull_request'` stellt sicher, dass nur tatsächliche Pushes auf `main` deployen.

**4. Warum wird der SSH-Key am Ende des Jobs mit `if: always()` wieder gelöscht, statt nur am erfolgreichen Ende?**

Der Key liegt während des Jobs unverschlüsselt auf dem Runner-Dateisystem. Schlägt ein vorheriger Schritt fehl (z. B. `rsync` bricht ab), würde der restliche Job normalerweise übersprungen — ohne `if: always()` bliebe der Key dann auf dem (kurzlebigen, aber trotzdem fremden) GitHub-Runner zurück, statt garantiert entfernt zu werden. `always()` sorgt dafür, dass der Aufräumschritt unabhängig vom Erfolg vorheriger Schritte ausgeführt wird.
