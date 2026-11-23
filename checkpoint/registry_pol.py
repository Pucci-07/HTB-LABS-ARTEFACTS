import registrypol

with open("Registry.pol", "rb") as file:
  policy = registrypol.load(file)
  for value in policy.values:
    print(f"Clé  : {value.key}")
    print(f"Valeur : {value.value}")
    print(f"Type   : {value.type}")
    print(f"Données: {value.data}")
    print("-" * 50)
