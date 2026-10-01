# concertpass

Actividad en clase — Sesión 13 (Desarrollo en la Nube, ITESO). Dos microservicios containerizados con Docker, publicados en Amazon ECR, con `ticket-api` escribiendo en PostgreSQL sobre RDS. Toda la infraestructura de AWS (RDS, security group, subnet group y repositorios de ECR) se define con Terraform.

```
concertpass/
├── apps
│   ├── ticket-api          # POST /reserve  -> inserta en RDS con status "confirmed"
│   │   ├── Dockerfile
│   │   ├── main.py
│   │   └── requirements.txt
│   └── ticket-checkout     # POST /checkout -> siempre 200
│       ├── Dockerfile
│       ├── main.py
│       └── requirements.txt
├── infra                     # Terraform
│   ├── versions.tf           # providers (aws, random, http, local)
│   ├── variables.tf
│   ├── main.tf               # SG, subnet group, RDS Postgres pública, repos ECR, genera ../.env
│   ├── outputs.tf            # db_host, registry_url, ecr_repository_urls...
│   └── terraform.tfvars.example
├── scripts
│   ├── schema.sql            # tabla reservations
│   ├── init_db.sh            # crea la tabla con psql
│   ├── publish_image.sh      # build + tag + push al repo ECR que creó Terraform
│   ├── run_ticket_api.sh     # docker run con --env-file .env
│   ├── check_reservations.sh # SELECT para validar
│   └── cleanup.sh            # DROP TABLE + terraform destroy
├── .env.example
└── .gitignore                # .env nunca se sube
```

Requisitos: Terraform ≥ 1.5, Docker, AWS CLI configurado (`aws sts get-caller-identity` debe funcionar), `psql` y `curl`.

## 0. Infraestructura con Terraform

```bash
cd infra
terraform init
terraform plan
terraform apply          
terraform output         
cd ..
```

Qué crea: un security group en la VPC por defecto que abre el 5432 solo a tu IP pública (se detecta sola; puedes fijarla con `allowed_cidr`), un subnet group, una instancia RDS PostgreSQL 16 `db.t3.micro` con `publicly_accessible = true`, los repositorios de ECR `ticket-checkout` y `ticket-api`, y el archivo `.env` en la raíz del repo con las variables `DB_*`. La contraseña la genera `random_password`, así que nunca se escribe a mano (consúltala con `terraform output -raw db_password`).

El state (`terraform.tfstate`) contiene la contraseña en texto plano: está en `.gitignore` y no se debe subir. En un equipo real se guardaría en un backend remoto (S3 con cifrado).

## 1. Repositorio

```bash
git init concertpass && cd concertpass   # o clona el repo que crearon en GitHub
# copia estos archivos
git add . && git commit -m "concertpass: ticket-checkout y ticket-api"
git remote add origin git@github.com:<equipo>/concertpass.git && git push -u origin main
```

## 2–4. ticket-checkout: local y ECR

```bash
docker build -t ticket-checkout apps/ticket-checkout
docker run -d --name ticket-checkout -p 8081:8080 ticket-checkout
curl -i -X POST http://localhost:8081/checkout      # HTTP/1.1 200 OK
./scripts/publish_image.sh ticket-checkout
```

(Se usa el puerto 8081 en el host para no chocar con ticket-api; dentro del contenedor ambos escuchan en 8080.)

## 5–6. ticket-api: RDS, local y ECR

```bash
# 1) La RDS y el .env ya los creó terraform apply (paso 0)

# 2) Crear la tabla (opcional: la app también la crea al arrancar)
./scripts/init_db.sh

# 3) Build y correr local apuntando a RDS (config por variables de ambiente)
docker build -t ticket-api apps/ticket-api
./scripts/run_ticket_api.sh
# equivalente a:
# docker run -p 8080:8080 -e DB_HOST=<rds_endpoint> -e DB_PORT=5432 -e DB_NAME=concertpass \
#   -e DB_USER=postgres -e DB_PASSWORD=<tu-password> ticket-api:latest

# 4) Probar
curl -i -X POST "http://localhost:8080/reserve" \
  -H "Content-Type: application/json" \
  -d '{"concert_id":"bad-bunny-gdl","user_id":"usr_123","ticket_type":"vip","quantity":2}'

# 5) Validar la fila en la BD
./scripts/check_reservations.sh

# 6) Publicar en ECR y volver a probar usando la imagen de ECR
./scripts/publish_image.sh ticket-api
FROM_ECR=1 ./scripts/run_ticket_api.sh
```

Respuesta esperada: `201 Created` con el `reservation_id` generado y `"status": "confirmed"`.

## 7. Limpieza

```bash
./scripts/cleanup.sh             # DROP TABLE reservations + terraform destroy (RDS, SG, ECR y .env)
./scripts/cleanup.sh --ecr-only  # DROP TABLE + destruye solo los repositorios de ECR
```

Los repos de ECR tienen `force_delete = true`, así que se destruyen aunque tengan imágenes. La RDS tiene `skip_final_snapshot = true` para que el destroy no se quede esperando un snapshot.

## Troubleshooting

`connection timeout` casi siempre es el security group: si cambiaste de red, tu IP pública cambió; corre `terraform apply` de nuevo y Terraform actualiza la regla sola. Si usas AWS Academy (Learner Lab), las credenciales expiran cada sesión: actualiza `~/.aws/credentials` antes de `apply` o `destroy`. Si ves `no pg_hba.conf entry ... no encryption`, falta SSL: deja `DB_SSLMODE=require`. Si tu laptop es Apple Silicon, `publish_image.sh` construye con `--platform linux/amd64` para que la imagen corra en instancias x86 de AWS.

## Preguntas de reflexión

**¿Dónde corre el contenedor? ¿Dónde corre la base de datos?**
El contenedor corre en nuestra laptop, sobre el Docker Engine local. La base de datos corre en AWS, en una instancia administrada de RDS PostgreSQL en us-east-1. ECR solo guarda la imagen; no la ejecuta.

**¿Esta configuración es 100% cloud?**
No, es una arquitectura híbrida: el cómputo es local y los datos están en la nube. Además tiene concesiones que no harías en producción: la RDS está expuesta a internet, cada request viaja desde tu red hasta us-east-1 (latencia) y la disponibilidad del servicio depende de que tu laptop esté encendida.

**¿Por qué debe evitarse el hardcoding aquí?**
Porque la misma imagen debe poder correr en cualquier ambiente (local, dev, prod, otra RDS) sin reconstruirse; cambiar un endpoint no debería requerir un nuevo build. También por seguridad: cualquier valor dentro de la imagen queda en sus capas y lo puede leer cualquiera que haga `docker pull` (por ejemplo con `docker history`), y si el código tiene la contraseña, queda expuesta en GitHub. Separar configuración de código es uno de los principios de las apps 12-factor.

**¿Qué tendrías que cambiar para que el contenedor también corra en la nube?**
Agregar a Terraform el cómputo que corra la imagen de ECR: ECS con Fargate (lo más directo), EKS, App Runner, una EC2 con Docker o Lambda con imagen de contenedor. Darle a ese servicio un rol IAM con permiso para hacer pull de ECR. Cambiar la RDS a `publicly_accessible = false` en subredes privadas en la misma VPC y cambiar la regla de ingreso para que use `referenced_security_group_id` (el SG del servicio) en lugar de `cidr_ipv4`. Guardar la contraseña en Secrets Manager (o usar `manage_master_user_password = true` en la RDS) e inyectarlas como variables de ambiente en la task definition en lugar de usar un `.env`. Como todo está en Terraform, estos cambios son modificaciones al código de `infra/` y no pasos manuales en la consola. Exponer el servicio con un Application Load Balancer o API Gateway, mandar logs a CloudWatch y cuidar que la arquitectura de la imagen (amd64/arm64) coincida con la del cómputo.
