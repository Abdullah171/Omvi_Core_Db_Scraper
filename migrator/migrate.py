import os
import sys
import time
import psycopg


DB_HOST = os.getenv("DB_HOST", "db")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "postgres")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")



def wait_for_db(max_seconds=120):
    start = time.time()
    while True:
        try:
            with psycopg.connect(
                host=DB_HOST,
                port=DB_PORT,
                dbname=DB_NAME,
                user=DB_USER,
                password=DB_PASSWORD,
                connect_timeout=3,
                autocommit=True,
            ) as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1;")
                    print("✅ Database is ready")
                    return
        except Exception as e:
            if time.time() - start > max_seconds:
                raise RuntimeError(f"Database not ready after {max_seconds}s") from e
            print("⏳ Waiting for database...")
            time.sleep(2)

def run_sql_file(path):
    with open(path, "r", encoding="utf-8") as f:
        sql = f.read()
    print(f"📜 Executing {path}")
    with psycopg.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        autocommit=True,
    ) as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
    print("✅ Schema applied successfully")

if __name__ == "__main__":


    sql_path = "schema.sql"
    # if len(sys.argv) < 2:
    #     print("Usage: python migrate.py /path/to/schema.sql")
    #     sys.exit(1)

    # sql_path = sys.argv[1]
    wait_for_db()
    run_sql_file(sql_path)
