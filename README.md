# Ali_cdt


FILE="eshoes.sh" && apt update -y && apt install -y curl && curl -sSL -H "Accept: application/vnd.github.v3.raw" -o $FILE "https://api.github.com/repos/xtonly/E-Shoes/contents/eshoes.sh?ref=main" && chmod +x $FILE && ./$FILE
