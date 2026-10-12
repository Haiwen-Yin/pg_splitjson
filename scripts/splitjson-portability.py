#!/usr/bin/env python3
"""Single-relation logical export/import using a consistent native snapshot.
Connection settings are supplied through libpq's standard environment/service.
No credentials or executable DDL enter the JSONL document.
"""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from splitjson_libpq import Connection, DatabaseError


def canonical(value):
    return (json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':'))+'\n').encode('utf-8')


def configure(db):
    db.execute("SET DateStyle='ISO,YMD'; SET TimeZone='UTC'; SET IntervalStyle='postgres'; SET extra_float_digits=3")


def export_relation(db, relation, path, subset=False, copy=()):
    configure(db)
    db.execute('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY')
    created = False
    try:
        manifest = json.loads(db.execute('SELECT splitjson.export_manifest($1::regclass,$2::boolean,$3::jsonb) m',
                              [relation, str(subset), json.dumps(list(copy))])[0]['m'])
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as out:
            created = True
            digest = hashlib.sha256()
            def write(item):
                line=canonical(item); digest.update(line); out.write(line)
            write({'manifest': manifest})
            count=0
            # This API uses native types and RLS under the captured caller. A
            # transaction owns the ACCESS SHARE lock until export completes.
            for row in db.execute('SELECT splitjson.export_rows($1::regclass,$2::boolean) r', [relation,str(subset)]):
                write({'row': json.loads(row['r'])}); count+=1
            out.write(canonical({'footer': {'rows':count,'sha256':digest.hexdigest()}}))
            out.flush(); os.fsync(out.fileno())
        db.execute('COMMIT')
        return count
    except BaseException:
        db.execute('ROLLBACK')
        if created:
            try: Path(path).unlink()
            except FileNotFoundError: pass
        raise


def import_relation(db, target, path, options=None):
    # Validate the whole stream before any target object is created.
    digest=hashlib.sha256(); manifest=None; count=0; footer=None
    with open(path,'rb') as source:
        for line in source:
            item=json.loads(line)
            if footer is not None: raise ValueError('data after footer')
            if 'footer' in item: footer=item['footer']; continue
            digest.update(line)
            if manifest is None:
                if set(item)!={'manifest'}: raise ValueError('missing manifest')
                manifest=item['manifest']
            elif set(item)=={'row'}: count+=1
            else: raise ValueError('invalid row record')
    if footer is None or footer.get('rows')!=count or footer.get('sha256')!=digest.hexdigest():
        raise ValueError('export checksum/count mismatch')
    configure(db); db.execute('BEGIN')
    try:
        db.execute('SELECT splitjson.import_manifest($1::jsonb,$2,$3::jsonb)', [json.dumps(manifest),target,json.dumps(options or {})])
        with open(path,'rb') as source:
            next(source)
            for line in source:
                item=json.loads(line)
                if 'footer' in item: break
                db.execute('SELECT splitjson.import_row($1::regclass,$2::jsonb)',[target,json.dumps(item['row'])])
        db.execute('SELECT splitjson.check_table($1::regclass,true)',[target])
        db.execute('COMMIT')
        return count
    except BaseException:
        db.execute('ROLLBACK'); raise


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command')
    exp=sub.add_parser('export'); exp.add_argument('--relation',required=True); exp.add_argument('--output',required=True)
    exp.add_argument('--subset',action='store_true'); exp.add_argument('--copy',default='')
    imp=sub.add_parser('import'); imp.add_argument('--target',required=True); imp.add_argument('--input',required=True)
    imp.add_argument('--options',default='{}',help='Declarative JSON, e.g. explicit role_map')
    args=parser.parse_args()
    if args.command is None: parser.error('a command is required')
    try:
        with Connection() as db:
            if args.command=='export': count=export_relation(db,args.relation,args.output,args.subset,filter(None,args.copy.split(',')))
            else: count=import_relation(db,args.target,args.input,json.loads(args.options))
        print(json.dumps({'operation':args.command,'rows':count,'snapshot_only':True}))
    except (DatabaseError,ValueError,OSError) as error:
        print(str(error) if isinstance(error,DatabaseError) else 'Invalid file or options; operation aborted.',file=sys.stderr)
        return 1
    return 0

if __name__=='__main__': sys.exit(main())
