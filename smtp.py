import os
import socket
import sys


def smtp_vrfy_file(target_ip, filename, port=25):
  # Vérification de l'existence du fichier
  if not os.path.exists(filename):
    print(f"[-] Erreur : Le fichier '{filename}' est introuvable.")
    return

  try:
    # Création de la socket TCP et connexion
    print(f"[*] Connexion à {target_ip}:{port}...")
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(20)
    s.connect((target_ip, port))

    # Réception de la bannière du serveur SMTP
    banner = s.recv(1024).decode('utf-8', errors='ignore')
    print(f"[<] Bannière reçue : {banner.strip()}")

    # Initialisation de la session avec HELO
    print('[*] Envoi de la commande HELO...')
    s.sendall(b'HELO test.local\r\n')
    response = s.recv(1024).decode('utf-8', errors='ignore')
    print(f"[<] Réponse HELO : {response.strip()}\n")

    # Chargement des utilisateurs depuis le fichier
    with open(filename, 'r', encoding='utf-8', errors='ignore') as f:
      users = [line.strip() for line in f if line.strip()]

    print(
        f"[*] Début du test pour {len(users)} utilisateurs issus de"
        f" '{filename}' :"
    )
    print('-' * 50)

    # Boucle sur chaque utilisateur du fichier
    for user in users:
      s.sendall(f'VRFY {user}\r\n'.encode('utf-8'))
      res = s.recv(1024).decode('utf-8', errors='ignore').strip()

      # Analyse du code de réponse SMTP
      if res.startswith('250'):
        print(f'[+] [VALIDE] {user} -> {res}')
      else:
        print(f'[-] [INVALIDE] {user} -> {res}')

    print('-' * 50)
    # Fermeture propre de la session SMTP
    s.sendall(b'QUIT\r\n')
    s.close()
    print('[*] Scan terminé. Connexion fermée.')

  except socket.timeout:
    print('[-] Erreur : Délai de connexion dépassé (Timeout).')
  except ConnectionRefusedError:
    print('[-] Erreur : Connexion refusée par le serveur.')
  except Exception as e:
    print(f'[-] Une erreur est survenue : {e}')


if __name__ == '__main__':
  # Configuration de la cible et du fichier de wordlist
  CIBLE_IP = '10.129.156.34'
  FICHIER_USERS = 'footprinting-wordlist.txt'

  smtp_vrfy_file(CIBLE_IP, FICHIER_USERS)
