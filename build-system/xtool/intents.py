#!/usr/bin/env python3
"""Emit the runtime-backed Swift declarations for this app's widget intents.

INIntent and INObject own storage and secure coding for @NSManaged properties.
Keep the .intentdefinition resources in the app for system configuration UI.
Unsupported schemas fail rather than guessing an ABI.
"""
import argparse
from pathlib import Path
import plistlib


def generate(source, destination):
    model = plistlib.loads(source.read_bytes())
    if model.get('INEnums'):
        raise ValueError('Intent enums need an explicit adapter')
    lines = ['import Foundation', 'import Intents', '']
    for obj in model['INTypes']:
        name = obj['INTypeName']
        lines += ['@available(iOS 13.0, *)', f'@objc({name})', f'public class {name}: INObject {{']
        for prop in obj['INTypeProperties']:
            if prop.get('INTypePropertyDefault'):
                continue
            if prop['INTypePropertyType'] != 'String' or prop.get('INTypePropertySupportsMultipleValues'):
                raise ValueError(f'Unsupported intent object property: {prop}')
            lines += [f'    @NSManaged public var {prop["INTypePropertyName"]}: String?']
        lines += ['}', '']
    for intent in model['INIntents']:
        name = intent['INIntentName'] + 'Intent'
        lines += ['@available(iOS 13.0, *)', f'@objc({name})', f'public class {name}: INIntent {{']
        methods = []
        for parameter in intent['INIntentParameters']:
            if parameter['INIntentParameterType'] != 'Object' or not parameter.get('INIntentParameterSupportsMultipleValues'):
                raise ValueError(f'Unsupported intent parameter: {parameter}')
            prop = parameter['INIntentParameterName']
            object_type = parameter['INIntentParameterObjectType']
            lines += [f'    @NSManaged public var {prop}: [{object_type}]?']
            title = prop[0].upper() + prop[1:]
            methods += ['    @available(iOS 14.0, *)', f'    @objc optional func provide{title}OptionsCollection(for intent: {name}, searchTerm: String?, with completion: @escaping (INObjectCollection<{object_type}>?, Error?) -> Void)', '    @available(iOS 14.0, *)', f'    @objc optional func default{title}(for intent: {name}) -> [{object_type}]?']
        lines += ['}', '', '@available(iOS 13.0, *)', f'@objc({name}Handling)', f'public protocol {name}Handling: NSObjectProtocol {{'] + methods + ['}', '']
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'WidgetIntents.swift').write_text('\n'.join(lines))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path('Telegram/SiriIntents/en.lproj/Intents.intentdefinition'))
    parser.add_argument('--output', type=Path, default=Path('build/xtool/generated/Telegram/GeneratedSources.Intent'))
    args = parser.parse_args()
    generate(args.source, args.output)
