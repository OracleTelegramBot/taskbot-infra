# 1. Crear el venv (donde tú prefieras tenerlo, p.ej. en ~/oci-tools)
python3 -m venv ~/oci-tools

# 2. Activarlo
source ~/oci-tools/bin/activate

# 3. Instalar la CLI
pip install --upgrade pip
pip install oci-cli

# 4. Verificar
oci --version

# 5. Generar config + llaves
oci setup config
