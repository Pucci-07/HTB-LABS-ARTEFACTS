
![[Pasted image 20260918212009.png]]

![[Pasted image 20260918212033.png]]

on a l'ip  cible donc on peut commencer par de la reconnaissance assez basique avec nmap 

![[Pasted image 20260918212646.png]]

on a que le port  80 et le 22 qui sont ouvert mais  le servive qui  va constituer un surface d'attaque  possible est les port  80 pour l'instant en  essayant d'y accéder on a  une redirection vers un domaine nommer metapress.htb (sa sent un peut le wordpress ici) 

![[Pasted image 20260918212931.png]]

donc il  faut s'assurer que  notre ip  cible pointe vers le domaine cible 'metapress.htb'  sur notre hote quand on veut la contacter donc essayer de modifier le ficheir  /etc/hosts sur linux comme ce ci 

![[Pasted image 20260918213401.png]] 

doonc une  fois sur le site on a : 

![[Pasted image 20260918213512.png]]

et maintenant on sait que c'est du worpress qui  est derrirère notre site web 

comme outiil d'enum principaux on a  
- nuclei
- wpscan

avec nuclei on a  : 

```bash
nuclei -u $url
```


![[Pasted image 20260918214530.png]]

on conait maintenant la version de wordpress qu'on a et ensuite u n utilisateurs valide du site qui est déployé : l'admin 

on va essayer de brutforcer la session de login  admin  qui se trouve a ce endpoint  avec wpscan 

```url
http://metapress.htb/wp-login.php?redirect_to=http%3A%2F%2Fmetapress.htb%2Fwp-admin%2F&reauth=1
```

![[Pasted image 20260918221247.png]]


```bash
wpscan --url http://example.com -U admin -P /chemin/ver/ta/wordlist 
```

![[Pasted image 20260919000244.png]] 
le brutforce ayant pris trop de temps on a : 
![[Pasted image 20260919000303.png]] 
rien donc le scan à été arrèter 

on va  d'abord voir les utlisiteurs du système : 

```bash
wpscan --url http://example.com --enumerate u 
```

![[Pasted image 20260919000525.png]] 
on a deux utilisateur  un user admin et manager on va relancer le bruteforce sur chaque user 


```bash
wpscan --url http://example.com -U admin -P /chemin/ver/ta/wordlist 
```


```bash
wpscan --url http://example.com -U manager -P /chemin/ver/ta/wordlist 
```
