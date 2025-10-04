script that grinds for keypairs and dumps them to a database with this schema
```
sol_keypairs(
  public_key varchar primary key,
  private_key bytea
)
```

make sure to have
- solana-keygen
- psql
- python

```
DATABASE_URL=xxx bash keypair_grinder.sh
```
