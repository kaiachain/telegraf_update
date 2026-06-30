#!/usr/bin/env python3
"""
Query InfluxDB log databases hourly and upload to GCS.
Run on node.kaia.io via cron.

GCS tree:
  gs://kaia-node-logs/kairos/{instance}/{instance}_log_YYYYMMDD-HH
  gs://kaia-node-logs/mainnet/{instance}/{prefix}_log_YYYYMMDD-HH
    (prefix = instance with -cn* suffix removed, e.g. kf-cn -> kf)
"""
import json, os, datetime, tempfile, subprocess
import urllib.request, urllib.parse

INFLUX_URL = "http://localhost:45560"
GCS_BUCKET = "kaia-node-logs"

DATABASES = {
    "kairos-log":  "kairos",
    "mainnet-log": "mainnet",
}


def influx_query(db, q):
    url = INFLUX_URL + "/query?" + urllib.parse.urlencode({"db": db, "q": q})
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.loads(r.read())


def get_instances(db):
    result = influx_query(db, "SHOW TAG VALUES FROM kaia_log WITH KEY = instance")
    try:
        return [row[1] for row in result["results"][0]["series"][0]["values"]]
    except (KeyError, IndexError):
        return []


def get_logs(db, instance, start, end):
    q = (
        f"SELECT value FROM kaia_log "
        f"WHERE instance='{instance}' "
        f"AND time >= '{start}' AND time < '{end}' "
        f"ORDER BY time ASC"
    )
    result = influx_query(db, q)
    try:
        return [row[1] for row in result["results"][0]["series"][0]["values"] if row[1]]
    except (KeyError, IndexError):
        return []


def file_prefix(instance, network):
    if network == "kairos":
        return instance  # full hostname: kairos-cn1_log_YYYYMMDD-HH
    # mainnet: strip -cn* suffix  (kf-cn -> kf,  mainnet-cn-2 -> mainnet)
    return instance.split("-cn")[0] if "-cn" in instance else instance


def upload_to_gcs(content, gcs_path):
    fd, tmp = tempfile.mkstemp(suffix=".log")
    try:
        os.write(fd, content.encode("utf-8", errors="replace"))
        os.close(fd)
        result = subprocess.run(
            ["gcloud", "storage", "cp", tmp, f"gs://{GCS_BUCKET}/{gcs_path}"],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            raise RuntimeError(f"gcloud cp failed: {result.stderr.strip()}")
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main():
    now  = datetime.datetime.utcnow().replace(minute=0, second=0, microsecond=0)
    prev = now - datetime.timedelta(hours=1)
    start    = prev.strftime("%Y-%m-%dT%H:%M:%SZ")
    end      = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    date_str = prev.strftime("%Y%m%d-%H")

    print(f"--- {now.strftime('%Y-%m-%d %H:%M')} UTC  window: {start} ~ {end} ---")

    for db, network in DATABASES.items():
        instances = get_instances(db)
        if not instances:
            print(f"[{network}] no instances in {db}")
            continue

        for instance in instances:
            lines = get_logs(db, instance, start, end)
            if not lines:
                print(f"[{network}/{instance}] no data for {date_str}")
                continue

            prefix   = file_prefix(instance, network)
            gcs_path = f"{network}/{instance}/{prefix}_log_{date_str}"
            content  = "\n".join(lines) + "\n"

            try:
                upload_to_gcs(content, gcs_path)
                print(f"[{network}/{instance}] {len(lines)} lines -> gs://{GCS_BUCKET}/{gcs_path}")
            except Exception as e:
                print(f"[{network}/{instance}] ERROR: {e}")


if __name__ == "__main__":
    main()
