from flask import Blueprint, request, render_template, flash, redirect, url_for
import sqlite3
import paramiko


def conn_sqlite():
    conn = sqlite3.connect('./test.db')
    cur = conn.cursor()
    cur.execute("select sqlite_version();")
    rows = cur.fetchall()
    for row in rows:
        print(row)
    conn.close()
    # return cur


main = Blueprint('main', __name__, url_prefix='/')


@main.route('/', methods=['GET'])
@main.route('/main', methods=['GET'])
def index():
    testData = 'testdata'
    return render_template('/index.html', testdatahtml=testData)


@main.route('/pgpool', methods=['GET'])
def pgpool():
    return render_template('/pgpool.html')


def execcommands():
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy)
    # cli.connect()
