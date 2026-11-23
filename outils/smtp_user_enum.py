import os
import socket
import sys
import time


def test_single_user(target_ip, user, port=25):
  try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect((target_ip, port))

    # Réception de la bannière
    s.recv(1024)

    # Initialisation HELO
    s.sendall(b"HELO test.local\r\n")
    s.recv(1024)

    # Envoi de la commande VRFY
    s.sendall(f"VRFY {user}\r\n".encode("utf-8"))
    response = s.recv(1024).decode("utf-8", errors="ignore").strip()

    # Fermeture propre
    s.sendall(b"QUIT\r\n")
    s.close()
    return response

  except socket.timeout:
    return "TIMEOUT"
  except Exception as e:
    return f"ERROR: {e}"


def smtp_vrfy_file(target_ip, filename, port=25):
  if not os.path.exists(filename):
    print(f"[-] Erreur : Le fichier '{filename}' est introuvable.")
    return

  with open(filename, "r", encoding="utf-8", errors="ignore") as f:
    users = [line.strip() for line in f if line.strip()]

  print(
      f"[*] Début du test pour {len(users)} utilisateurs (Nouvelle connexion"
      " par utilisateur)..."
  )
  print("-" * 50)

  for user in users:
    res = test_single_user(target_ip, user, port)

    if res.startswith("250"):
      print(f"[+] [VALIDE] {user} -> {res}")
    elif "550" in res:
      print(f"[-] [INVALIDE] {user} -> {res}")
    else:
      print(f"[!] [AUTRE] {user} -> {res}")

    # Petite pause pour ne pas surcharger le service
    time.sleep(0.3)

  print("-" * 50)
  print("[*] Scan terminé.")


if __name__ == "__main__":
  CIBLE_IP = "10.129.156.34"
  FICHIER_USERS = "footprinting-wordlist.txt"

  smtp_vrfy_file(CIBLE_IP, FICHIER_USERS)
