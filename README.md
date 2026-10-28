# Ali_cdt


FILE="Ali_cdt.sh" && apt update -y && apt install -y curl && curl -sSL -H "Accept: application/vnd.github.v3.raw" -o $FILE "https://api.github.com/repos/xtonly/Ali_cdt/refs/heads/main" && chmod +x $FILE && ./$FILE
