# Concertpass

Práctica 3 · Desarrollo en la Nube · ITESO

Sistema de reservación de boletos para conciertos con tres microservicios en Amazon EKS. Cuando la demanda supera el aforo, los primeros en llegar obtienen su boleto y el resto recibe `rejected`, sin sobreventa aunque haya varios workers procesando a la vez.

## Arquitectura

```
                         ┌──────────────── EKS concertpass-cluster (2 x t3.medium) ────────────────┐
 cliente ──POST /reserve────▶ Service ticket-api (NodePort 30080) ──▶ ticket-api (2 réplicas)    │
         ◀─GET /reservation/{id}─┘                                     │  1. INSERT pending ──────┼──▶ RDS PostgreSQL
                         │                                             │  2. send_message ────────┼──▶ SQS FIFO
                         │                                                                       │   (MessageGroupId
                         │   ticket-worker (1 réplica, escalable a 3) ◀── polling ───────────────┼──── = concert_id)
                         │     3. capacidad de la sección ──────────────────────────────────────┼──▶ DynamoDB (eventos)
                         │     4. BEGIN; SELECT ... FOR UPDATE; SUM vendidos; booked | rejected ─┼──▶ RDS
                         │     5. POST /checkout ──▶ Service ticket-checkout ──▶ ticket-checkout │
                         │     6. 200 OK → UPDATE confirmed ────────────────────────────────────┼──▶ RDS
                         └───────────────────────────────────────────────────────────────────────┘
   Secrets Manager concertpass/rds ──(External Secrets Operator, rol LabRole)──▶ Secret rds-credentials ──▶ env DB_*
```

Estados de una reservación: `pending → booked → confirmed`, o `pending → rejected` si no hay espacio.

| Servicio | Qué hace | Kubernetes |
|---|---|---|
| `ticket-api` | `POST /reserve` guarda `pending` en RDS, encola en SQS y regresa `reservation_id`. `GET /reservation/{id}` regresa el estado. | Deployment (2) + Service **NodePort** 30080 |
| `ticket-worker` | Consume SQS, lee la capacidad en DynamoDB, decide con `FOR UPDATE` en RDS, llama a checkout y marca `confirmed`. | Deployment (**1 réplica**) |
| `ticket-checkout` | Simula un procesador de pagos: `POST /checkout` responde 200 OK. | Deployment (2) + Service ClusterIP |

## Estructura

```
concertpass/
├── ticket-api/            Dockerfile, requirements.txt, src/main.py
├── ticket-worker/         Dockerfile, requirements.txt, src/main.py
├── ticket-checkout/       Dockerfile, requirements.txt, src/main.py
├── k8s/
│   ├── namespace.yaml
│   ├── configmap.yaml                 AWS_REGION, SQS_QUEUE_URL, DYNAMODB_TABLE, CHECKOUT_URL
│   ├── external-secret.yaml           Secrets Manager → Secret rds-credentials (External Secrets)
│   ├── ticket-api-deployment.yaml     ticket-api-service.yaml (NodePort)
│   ├── ticket-worker-deployment.yaml
│   └── ticket-checkout-deployment.yaml  ticket-checkout-service.yaml
├── infra/                 Terraform: RDS, SQS FIFO + DLQ, DynamoDB, Secrets Manager, ECR
├── scripts/
│   ├── setup.sh                 levanta todo en orden
│   ├── teardown.sh              destruye todo y verifica (contraparte de setup.sh)
│   ├── verify_teardown.sh       lista lo que quede en AWS
│   ├── eks_up.sh                cluster eksctl + External Secrets + red
│   ├── eksctl-cluster.yaml      configuración del cluster (2 x t3.medium, LabRole)
│   ├── deploy_k8s.sh            kubectl apply de k8s/
│   ├── init_db.sh, schema.sql   tablas en RDS
│   ├── seed_dynamodb.sh, data/concerts.json   precarga de conciertos
│   ├── publish_all.sh, publish_image.sh       imágenes a ECR
│   ├── validate_k8s.sh          revisión rápida de punta a punta
│   ├── show_sqs_message.sh      evidencia de que el mensaje llega a SQS
│   ├── scenario_niche.sh        escenario 1: concierto de nicho
│   ├── scenario_high_demand.sh  escenario 2: alta demanda con 3 workers
│   ├── show_state.sh            estado en DynamoDB y RDS
│   └── race_test.py             prueba de concurrencia de la lógica de inventario
└── README.md
```

El enunciado menciona `concertpass/apps/scripts/` en la sección 1.10 y `scripts/` en el árbol de la 1.11; seguimos el árbol.

## Requisitos

Terraform ≥ 1.5, AWS CLI, Docker, eksctl, kubectl, helm, psql, python3 y curl.

### AWS Academy Learner Lab

El proyecto está hecho para correr en una cuenta de Learner Lab. Estas son las restricciones que afectan y cómo se resuelven:

| Restricción de Learner Lab | Cómo se resuelve |
|---|---|
| No se pueden crear roles IAM ni proveedores OIDC | El cluster y los nodos usan el rol precreado **`LabRole`** (`scripts/eksctl-cluster.yaml`). Por eso el cluster se crea con `eksctl create cluster -f` y no solo con flags: sin `serviceRoleARN` e `instanceRoleARN`, eksctl intenta crear sus propios roles y falla. |
| Sin roles propios no hay IRSA ni EKS Pod Identity | Los pods usan las credenciales de `LabRole` heredadas del nodo vía IMDS (eksctl deja el *hop limit* en 2, así que los pods sí llegan). Para Secrets Manager se usa **External Secrets Operator** en lugar del CSI Driver, porque el provider de AWS del CSI Driver solo funciona con IRSA o Pod Identity. |
| Solo `us-east-1` y `us-west-2` | Todo usa `us-east-1`; `setup.sh` lo verifica. |
| EC2 hasta `large`, máximo 32 vCPU y 9 instancias; RDS hasta `medium`, sin Multi-AZ, gp2 | 2 × `t3.medium` (4 vCPU) y RDS `db.t3.micro` en gp2 sin Multi-AZ. |
| Presupuesto limitado del lab | Sin NAT Gateway (los nodos van en subredes públicas). Costo aproximado de 0.30 USD/h mientras el cluster existe. Al terminar cada sesión de trabajo: `./scripts/teardown.sh --eks-only`. |

Los demás servicios (DynamoDB, SQS, Secrets Manager, ECR, CloudFormation, VPC) están disponibles sin restricciones relevantes.

**Credenciales.** En la página del lab: *AWS Details → AWS CLI → Show*. Copia el bloque completo (incluye `aws_session_token`) a `~/.aws/credentials` y verifica con `aws sts get-caller-identity` (el ARN debe contener `voclabs`). Las credenciales cambian en cada sesión del lab: actualízalas antes de correr cualquier script, incluido `kubectl`, que usa `aws eks get-token`.

**Al cerrar la sesión del lab**, AWS puede detener las instancias EC2, incluidos los nodos. Al volver, los nodos regresan con otra IP pública. Corre `./scripts/eks_up.sh` para actualizar las reglas del security group (es idempotente) y revisa `kubectl get nodes`.

## Levantar todo

```bash
./scripts/setup.sh
```

Tarda unos 25 minutos la primera vez, casi todo en crear el cluster. Los pasos son idempotentes: si algo falla, se corrige y se vuelve a correr.

1. **Terraform** (`infra/`): RDS PostgreSQL con su security group, cola `concertpass-reservations.fifo` con su DLQ, tabla DynamoDB `concertpass-events`, secreto `concertpass/rds` y repositorios ECR. Genera `.env` (en `.gitignore`) para los scripts.
2. **Datos**: crea las tablas en RDS y precarga tres conciertos en DynamoDB.
3. **ECR**: build `linux/amd64` y push de las tres imágenes.
4. **EKS**: `eksctl create cluster -f scripts/eksctl-cluster.yaml` con 2 nodos `t3.medium` administrados y `LabRole`, External Secrets Operator con Helm, y reglas de red (nodos → RDS, tu IP → NodePort).
5. **Kubernetes**: `kubectl apply` de `k8s/`.

Conciertos precargados (`scripts/data/concerts.json`):

| concert_id | Para qué | floor | vip | general |
|---|---|---|---|---|
| `bad-bunny-gdl` | ejemplo del enunciado | 100 | 50 | 500 |
| `jazz-trio-gdl` | escenario de nicho | 20 | 10 | 50 |
| `karol-g-gdl` | alta demanda (aforo chico, se agota rápido) | 10 | 5 | 20 |

## Guion para el video

| Paso | Comando | Muestra |
|---|---|---|
| Cluster | `kubectl get nodes`<br>`kubectl -n concertpass get pods,services` | 2 nodos Ready, 5 pods, NodePort 30080 |
| Mensaje en SQS | `./scripts/show_sqs_message.sh` | pausa el worker, reserva, muestra el mensaje en la cola con `MessageGroupId = concert_id`, enciende el worker y la reserva pasa a `confirmed` |
| Escenario de nicho | `./scripts/scenario_niche.sh` | evento en DynamoDB, 4 reservaciones, todas `confirmed` vía `GET /reservation/{id}` y en RDS |
| Alta demanda | `./scripts/scenario_high_demand.sh` | escala ticket-worker a 3 réplicas, 30 reservaciones en paralelo para 5 boletos VIP, 5 `confirmed` y 25 `rejected`, comprobación de que no hay sobreventa y decisiones por pod |
| Estado | `./scripts/show_state.sh` | resumen por sección y estado en RDS, eventos en DynamoDB |
| Limpieza | `./scripts/teardown.sh` | destruye todo y lista cada servicio como `eliminado` |

Variables útiles: `CONCERT`, `TICKET`, `REQUESTS`, `PARALLEL`, `QTY`, `WORKERS` y `RESET=0` (para no borrar reservaciones previas del concierto). Por ejemplo, `CONCERT=bad-bunny-gdl TICKET=vip REQUESTS=150 PARALLEL=40 ./scripts/scenario_high_demand.sh`. Los scripts llegan al API por NodePort y, si no responde, abren `kubectl port-forward svc/ticket-api 8080:8080` solos.

Prueba manual:

```bash
kubectl -n concertpass port-forward svc/ticket-api 8080:8080
curl -X POST http://localhost:8080/reserve -H "Content-Type: application/json" \
  -d '{"concert_id":"bad-bunny-gdl","user_id":"usr_123","ticket_type":"vip","quantity":2}'
curl http://localhost:8080/reservation/<reservation_id>
```

## Cómo evita la sobreventa ticket-worker

El enunciado sugiere `SELECT COALESCE(SUM(quantity), 0) ... FOR UPDATE`. Tal cual, PostgreSQL lo rechaza:

```
ERROR:  FOR UPDATE is not allowed with aggregate functions
```

Reescribirlo como subconsulta (`SUM` sobre un `SELECT ... FOR UPDATE`) tampoco basta. Solo bloquea las filas `booked`/`confirmed` que ya existen: con el concierto vacío no bloquea nada, y dos workers ven "0 vendidos" al mismo tiempo. Además, en READ COMMITTED una fila que otro worker acaba de marcar como `booked` no entra en el conjunto que ya se leyó.

Por eso el worker hace `FOR UPDATE` sobre una fila de candado por sección en la tabla `inventory_locks (concert_id, ticket_type)`:

```sql
BEGIN;
SELECT 1 FROM inventory_locks WHERE concert_id = :c AND ticket_type = :t FOR UPDATE;  -- candado de la sección
SELECT status FROM reservations WHERE reservation_id = :id FOR UPDATE;               -- ¿sigue pending?
SELECT COALESCE(SUM(quantity), 0) FROM reservations
 WHERE concert_id = :c AND ticket_type = :t AND status IN ('booked','confirmed');
-- si vendidos + quantity <= capacity[ticket_type] (DynamoDB):
UPDATE reservations SET status = 'booked', updated_at = NOW() WHERE reservation_id = :id;
COMMIT;
-- si no: ROLLBACK, y en otra transacción:
UPDATE reservations SET status = 'rejected', updated_at = NOW()
 WHERE reservation_id = :id AND status = 'pending';
```

Todos los workers que quieran vender boletos de la misma sección se forman en esa fila. Como el `SUM` corre después de obtener el candado, siempre ve lo que confirmó el worker anterior. Secciones distintas no se bloquean entre sí.

`scripts/race_test.py` lo demuestra con 30 workers simultáneos peleando por 10 boletos (`python3 scripts/race_test.py`, usa la RDS de `.env`):

```
enunciado  capacidad=10 solicitudes=30 -> booked=30 rejected=0   [SOBREVENTA: 20 boletos de más]
worker     capacidad=10 solicitudes=30 -> booked=10 rejected=20  [OK, sin sobreventa]
```

### Otras decisiones

- **COMMIT antes de encolar.** `ticket-api` confirma el `INSERT` y después manda el mensaje. Si encolara dentro de la transacción, el worker podría recibir el mensaje antes del `COMMIT` y no encontrar la fila (lo vimos en las pruebas: la reservación se quedaba en `pending`). Si SQS falla, el API borra la fila y responde 503.
- **Idempotencia.** SQS puede entregar un mensaje más de una vez. El worker solo decide si la fila sigue en `pending`; si ya está `booked`, únicamente reintenta el checkout. Los `UPDATE` filtran por `reservation_id` y por el estado esperado, así que nunca tocan otras filas.
- **Fallos de pago.** Si `ticket-checkout` no responde 200, el mensaje no se borra: SQS lo reentrega tras el visibility timeout y la reservación pasa de `booked` a `confirmed` sin volver a contarse. Tras 5 intentos fallidos el mensaje va a la DLQ `concertpass-reservations-dlq.fifo`, para no bloquear el MessageGroup del concierto.
- **Orden dentro del lote.** El worker recibe hasta 10 mensajes. Si uno falla, deja el resto del lote para conservar el orden FIFO del grupo.
- **`MessageDeduplicationId = reservation_id`.** Con solo la deduplicación por contenido, dos reservaciones idénticas en menos de 5 minutos se descartarían en silencio.
- **Respuesta 202 Accepted** en `POST /reserve`, porque el resultado se decide después. Un concierto o una sección que no existen en DynamoDB terminan en `rejected`.

## Configuración y credenciales

Ningún servicio tiene valores de configuración en el código; todo llega por variables de ambiente.

- **Credenciales de RDS** en Secrets Manager (`concertpass/rds`, creado por Terraform). `k8s/external-secret.yaml` define un `SecretStore` (dónde leer) y un `ExternalSecret` (qué leer). External Secrets Operator lee el secreto con el rol `LabRole` del nodo y lo copia al Secret `rds-credentials`. `ticket-api` y `ticket-worker` lo reciben como variables `DB_*` con `secretKeyRef`. Si se cambia la contraseña en Secrets Manager, el Secret se actualiza en menos de una hora.
- **El resto** (`AWS_REGION`, `SQS_QUEUE_URL`, `DYNAMODB_TABLE`, `CHECKOUT_URL`) va en el ConfigMap `concertpass-config`.
- **Permisos.** En Learner Lab todos los pods comparten `LabRole` a través del nodo. En una cuenta normal lo correcto sería un rol por pod con IRSA o EKS Pod Identity, con mínimo privilegio: el API solo `sqs:SendMessage`, el worker solo `ReceiveMessage`/`DeleteMessage`, `dynamodb:GetItem` y `secretsmanager:GetSecretValue`. Vale la pena mencionarlo en el reporte como limitación del entorno.

## Puntos para el reporte

Borradores para las tres preguntas; ajústalos con lo que observen en el video.

**¿Para qué sirve SQS FIFO con MessageGroupId y cómo se usa aquí?** Una cola FIFO garantiza orden de entrega y procesamiento exactamente una vez (con deduplicación) dentro de cada MessageGroup. `ticket-api` usa `concert_id` como `MessageGroupId`, así que las reservaciones de un concierto se procesan en el orden en que llegaron: los primeros en reservar son los primeros en obtener boleto. SQS no entrega el siguiente mensaje de un grupo mientras el anterior siga en proceso. Por eso conciertos distintos sí se procesan en paralelo, y un concierto suele concentrarse en un solo worker (en las pruebas, un pod tomó las 150 decisiones de `bad-bunny-gdl`). Desacopla la recepción del procesamiento: el API responde en milisegundos aunque el worker vaya atrasado.

**¿Qué problema resuelve FOR UPDATE y cuál es el trade-off?** Evita la condición de carrera de "leer disponibilidad y luego escribir". Sin bloqueo, dos workers leen "quedan 2" al mismo tiempo y ambos venden. `FOR UPDATE` toma un candado de fila: el segundo worker espera hasta el `COMMIT` o `ROLLBACK` del primero y entonces ve el inventario actualizado. Así, vendidos nunca supera la capacidad. El trade-off es que las ventas de una misma sección quedan serializadas. Agregar workers o réplicas del API no acelera la venta de un concierto popular, solo la recepción de requests; el cuello de botella es la sección de inventario (leer, bloquear y escribir). Secciones y conciertos distintos sí escalan. Se gana consistencia a cambio de concurrencia, que es lo correcto para dinero y aforo. Alternativas a escala serían contadores atómicos en Redis o DynamoDB, o reservar bloques de inventario por worker.

**¿Qué beneficios da EKS aquí?** Cada servicio escala por separado (`kubectl scale`). Kubernetes reinicia pods caídos con los probes de liveness y readiness. El DNS interno conecta al worker con checkout (`http://ticket-checkout:8080`) sin IPs fijas. Las credenciales se inyectan sin tocar las imágenes. Y el control plane lo administra AWS, con integración nativa a IAM (Pod Identity), ECR y Secrets Manager. Los mismos manifiestos sirven para cualquier ambiente.

## Destruir todo

```bash
./scripts/teardown.sh             # cluster + tablas + terraform destroy, y verificación final
./scripts/teardown.sh --eks-only  # solo el cluster (lo más caro); lo demás se queda para la siguiente sesión
```

Al terminar cada sesión de trabajo borra por lo menos el cluster: el control plane y los dos nodos cobran por hora aunque no se usen. `verify_teardown.sh` revisa EKS, EC2, los stacks de eksctl, RDS, SQS, DynamoDB, ECR, Secrets Manager y el security group, y marca cada uno como `eliminado`.

## Troubleshooting

- **eksctl falla con `AccessDenied` al crear roles** (`iam:CreateRole`): se está creando el cluster sin `scripts/eksctl-cluster.yaml`. Usa `./scripts/eks_up.sh`, que pasa `LabRole`. Si el error menciona `iam:PassRole` o `LabRole`, revisa que las credenciales sean de la sesión actual del lab.
- **Pods en `CreateContainerConfigError` con *secret "rds-credentials" not found***, o `deploy_k8s.sh` se queda esperando el ExternalSecret: External Secrets no pudo leer Secrets Manager. Revisa `kubectl -n concertpass describe externalsecret rds-credentials` y `kubectl -n external-secrets logs deploy/external-secrets`. Un `AccessDenied` ahí significa que el nodo no tiene `LabRole`; un error de IMDS o de *no credentials* significa que el *hop limit* del nodo es 1 (no debería pasar con eksctl; revisa con `aws ec2 describe-instances --query 'Reservations[].Instances[].MetadataOptions'`).
- **`ExpiredToken` en kubectl, terraform o aws**: terminó la sesión del lab. Copia las credenciales nuevas a `~/.aws/credentials`.
- **`CrashLoopBackOff`**: casi siempre el pod no llega a la RDS (`kubectl -n concertpass logs deploy/ticket-worker`). Las IPs de `kubectl get nodes -o wide` deben estar en `infra/eks.auto.tfvars.json`. Si los nodos se reemplazaron, vuelve a correr `./scripts/eks_up.sh`.
- **`ImagePullBackOff`**: falta la imagen en ECR (`./scripts/publish_all.sh`).
- **Reservaciones que se quedan en `booked`**: el worker no llega a checkout. Revisa `kubectl -n concertpass get endpoints ticket-checkout` y los logs del worker.
- **Timeout de psql desde tu laptop**: cambió tu IP pública. `terraform -chdir=infra apply` actualiza la regla.

## Historial

- **Parte 1**: servicios en Docker, imágenes en ECR, `ticket-api` escribiendo en RDS.
- **Parte 2**: flujo asíncrono con SQS FIFO; `ticket-worker` consume la cola.
- **Parte 3**: despliegue en EKS con Secrets Manager.
- **Práctica 3**: `GET /reservation/{id}`, decisión de inventario con DynamoDB y `FOR UPDATE`, checkout y `confirmed`, escenarios de prueba, `setup.sh` y `teardown.sh`, adaptado a AWS Academy Learner Lab (LabRole y External Secrets).
