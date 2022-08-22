# starknet-plugin-account

A community project to standardise the use of plugins in StarkNet account contracts.

## Development

### Setup a local virtual env

```
python -m venv ./venv
source ./venv/bin/activate
```

### Install Cairo dependencies
```
brew install gmp
```

```
pip install -r requirements.txt
```

See for more details:
- https://www.cairo-lang.org/docs/quickstart.html
- https://github.com/martriay/nile

### Compile the contracts
```
nile compile
```
