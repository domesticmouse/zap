import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/syntactic_entity.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:collection/collection.dart';

import 'tree.dart';

import '../resolver/component.dart';
import '../resolver/dart.dart';
import '../resolver/flow.dart';
import '../resolver/resolver.dart';
import '../resolver/reactive_dom.dart';
import '../resolver/preparation.dart';
import '../utils/dart.dart';

const _prefix = r'_$';
const _parentField = '${_prefix}parent';

class Generator {
  final GenerationScope libraryScope = GenerationScope();

  final PrepareResult prepareResult;
  final ResolvedComponent component;

  final Map<BaseZapVariable, String> _varNames = {};
  final Map<ReactiveNode, String> _nodeNames = {};
  final Map<FunctionElement, String> _functionNames = {};
  final Map<Object, String> _miscNames = {};

  Generator(this.component, this.prepareResult);

  String _nameForVar(BaseZapVariable variable) {
    return _varNames.putIfAbsent(variable, () {
      return '${_prefix}v${_varNames.length}';
    });
  }

  String _nameForNode(ReactiveNode node) {
    return _nodeNames.putIfAbsent(node, () {
      return '${_prefix}n${_nodeNames.length}';
    });
  }

  String _nameForFunction(FunctionElement fun) {
    return _functionNames.putIfAbsent(fun, () => '${_prefix}fun_${fun.name}');
  }

  String _nameForMisc(Object key) {
    return _miscNames.putIfAbsent(
        key, () => '_${_prefix}t${_miscNames.length}');
  }

  void write() {
    final imports = ScriptComponents.of(prepareResult.temporaryDartFile,
            rewriteImports: ImportRewriteMode.apiToGenerated)
        .directives;
    final buffer = libraryScope.leaf();

    buffer
      ..writeln('// Generated by zap_dev, do not edit!')
      ..writeln("import 'dart:html' as $_prefix;")
      // We're importing zap with and without a name to use extensions while
      // also avoiding naming conflicts otherwise.
      ..writeln("import 'package:zap/zap.dart';")
      ..writeln("import 'package:zap/zap.dart' as $_prefix;")
      ..writeln(imports);

    _writeComponent(component.component);
  }

  void _writeComponent(ComponentOrSubcomponent component) {
    _ComponentOrSubcomponentWriter writer;
    final scope = libraryScope.inner(ScopeLevel.$class);

    if (component is Component) {
      writer = _ComponentWriter(
          component, this.component.componentName, this, scope);
    } else {
      writer =
          _SubComponentWriter(component as ResolvedSubComponent, this, scope);
    }

    writer.write();

    component.children.forEach(_writeComponent);
  }
}

abstract class _ComponentOrSubcomponentWriter {
  final Generator generator;
  final GenerationScope classScope;
  final StringBuffer buffer;

  ComponentOrSubcomponent get component;

  _ComponentOrSubcomponentWriter(this.generator, this.classScope)
      : buffer = classScope.leaf();

  bool _onlyRendersSubcomponents(ReactiveNode node) =>
      node is SubComponent || node is ReactiveIf || node is ReactiveAsyncBlock;

  bool _isInitializedLater(ReactiveNode node) =>
      _onlyRendersSubcomponents(node);

  void write();

  void writeNodesAndBlockHelpers() {
    // Write instance fields storing DOM nodes or zap block helpers
    for (final node in component.fragment.allNodes) {
      final name = generator._nameForNode(node);
      final isInitializedLater = _isInitializedLater(node);

      if (isInitializedLater) {
        buffer.write('late ');
      }

      buffer
        ..write('final ')
        ..write(node.dartTypeName!)
        ..write(' ')
        ..write(name);

      if (!isInitializedLater) {
        buffer.write(' = ');
        createNode(node);
      }

      buffer.writeln(';');

      if (node is ReactiveIf) {
        // Write a function used to evaluate the condition for an if block
        final name = generator._nameForMisc(node);
        buffer.writeln('int $name() {');
        for (var i = 0; i < node.conditions.length; i++) {
          if (i != 0) {
            buffer.write('else ');
          }
          buffer.write('if(');
          writeDartWithPatchedReferences(node.conditions[i].expression);
          buffer
            ..writeln(') {')
            ..writeln('  return $i;')
            ..writeln('}');
        }
        buffer.writeln('else { return ${node.conditions.length}; }}');
      }
    }
  }

  void writeCreateMethod() {
    final name = component is Component ? 'createInternal' : 'create';

    buffer.writeln('@override void $name() {');

    // Create subcomponents. They require evaluating Dart expressions, so we
    // can't do this earlier.
    for (final node in component.fragment.allNodes) {
      if (_isInitializedLater(node)) {
        buffer
          ..write(generator._nameForNode(node))
          ..write(' = ');
        createNode(node);
        buffer.writeln(';');
      }
    }

    // In the create method, we set the initial value of Dart expressions and
    // register event handlers.
    for (final flow in component.flows) {
      if (flow.isOneOffAction) {
        writeFlowAction(flow, isInCreate: true);
      }
    }

    buffer.writeln('}');
  }

  void writeMountMethod() {
    final name = component is Component ? 'mountInternal' : 'mount';

    buffer
      ..writeln('@override')
      ..writeln(
          'void $name($_prefix.Element target, [$_prefix.Node? anchor]) {');

    void writeAdd(Iterable<ReactiveNode> nodes, String target, String? anchor) {
      for (final node in nodes) {
        final name = generator._nameForNode(node);

        if (_onlyRendersSubcomponents(node)) {
          buffer
            ..write(name)
            ..writeln('.mount($target, $anchor);');
          continue;
        } else if (anchor == null) {
          // Write an append call
          buffer.writeln('$target.append($name);');
        } else {
          // Use insertBefore then
          buffer.writeln('$target.insertBefore($name, $anchor);');
        }

        // Mount child nodes as well
        writeAdd(node.children, name, null);
      }
    }

    writeAdd(component.fragment.rootNodes, 'target', 'anchor');
    buffer.writeln('}');
  }

  void writeRemoveMethod() {
    final name = component is Component ? 'remove' : 'destroy';

    buffer
      ..writeln('@override')
      ..writeln('void $name() {');

    for (final rootNode in component.fragment.rootNodes) {
      buffer.write(generator._nameForNode(rootNode));

      if (_onlyRendersSubcomponents(rootNode)) {
        // use .destroy() to unmount zap components
        buffer.write('.destroy();');
      } else {
        // and .remove() to unmount `dart:html` elements.
        buffer.write('.remove();');
      }
    }

    buffer.writeln('}');
  }

  void writeUpdateMethod() {
    buffer
      ..writeln('@override')
      ..writeln('void update(int delta) {');

    for (final flow in component.flows) {
      if (!flow.isOneOffAction) {
        buffer
          ..write('if (delta & ')
          ..write(flow.bitmask)
          ..writeln(' != 0) {');
        writeFlowAction(flow);
        buffer.writeln('}');
      }
    }

    // Some nodes manage subcomponents and need to be updated as well
    for (final node
        in component.fragment.allNodes.where(_onlyRendersSubcomponents)) {
      final name = generator._nameForNode(node);
      buffer.writeln('$name.update(delta);');
    }

    buffer.writeln('}');
  }

  void writeFlowAction(Flow flow, {bool isInCreate = false}) {
    final action = flow.action;

    if (action is SideEffect) {
      writeDartWithPatchedReferences(action.statement);
    } else if (action is ChangeText) {
      writeSetText(action.text);
    } else if (action is RegisterEventHandler) {
      final handler = action.handler;
      if (flow.isOneOffAction) {
        // Just register the event handler, it won't be changed later!
        registerEventHandler(handler);
      } else {
        if (isInCreate) {
          // We need to store the result of listening in a stream subscription
          // so that the event handler can be changed later.
          buffer
            ..write(generator._nameForMisc(handler))
            ..write(' = ');
          registerEventHandler(handler);
        } else {
          // Just change the onData callback of the stream subscription now
          buffer
            ..write(generator._nameForMisc(handler))
            ..write('onData(');
          callbackForEventHandler(handler);
          buffer.writeln(');');
        }
      }
    } else if (action is ApplyAttribute) {
      final attribute = action.element.attributes[action.name]!;
      final nodeName = generator._nameForNode(action.element);

      switch (attribute.mode) {
        case AttributeMode.setValue:
          // Just emit node.attributes[key] = value.toString()
          buffer
            ..write(nodeName)
            ..write(".attributes['")
            ..write(action.name)
            ..write("'] = ");
          writeDartWithPatchedReferences(
              attribute.backingExpression.expression);
          buffer.writeln('.toString();');
          break;
        case AttributeMode.addIfTrue:
          // Emit node.applyBooleanAttribute(key, value)
          buffer
            ..write(nodeName)
            ..write(".applyBooleanAttribute('")
            ..write(action.name)
            ..write("', ");
          writeDartWithPatchedReferences(
              attribute.backingExpression.expression);
          buffer.writeln(');');
          break;
        case AttributeMode.setIfNotNullClearOtherwise:
          buffer
            ..write(nodeName)
            ..write(".applyAttributeIfNotNull('")
            ..write(action.name)
            ..write("', ");
          writeDartWithPatchedReferences(
              attribute.backingExpression.expression);
          buffer.writeln(');');
          break;
      }
    } else if (action is UpdateIf) {
      final nodeName = generator._nameForNode(action.node);
      final nameOfBranchFunction = generator._nameForMisc(action.node);

      buffer
        ..write(nodeName)
        ..write('.reEvaluate($nameOfBranchFunction());');
    } else if (action is UpdateAsyncValue) {
      final block = action.block;
      final nodeName = generator._nameForNode(block);

      final setter = block.isStream ? 'stream' : 'future';
      final wrapper =
          block.isStream ? '$_prefix.\$safeStream' : '$_prefix.\$safeFuture';
      final type = block.type.getDisplayString(withNullability: true);

      buffer.write('$nodeName.$setter = $wrapper<$type>(() => ');
      writeDartWithPatchedReferences(block.expression.expression);
      buffer.write(');');
    }
  }

  void registerEventHandler(EventHandler handler) {
    final knownEvent = handler.knownType;
    final node = generator._nameForNode(handler.parent);

    buffer
      ..write(node)
      ..write('.');

    if (knownEvent != null) {
      // Use the known Dart getter for the event stream
      buffer.write(knownEvent.getterName);
    } else {
      // Use on[name] instead
      buffer
        ..write("on['")
        ..write(handler.event)
        ..write("']");
    }

    if (handler.modifier.isNotEmpty) {
      // Transform the event stream to account for the modifiers.
      buffer.write('.withModifiers(');

      for (final modifier in handler.modifier) {
        switch (modifier) {
          case EventModifier.preventDefault:
            buffer.write('preventDefault: true,');
            break;
          case EventModifier.stopPropagation:
            buffer.write('stopPropagation: true,');
            break;
          case EventModifier.passive:
            buffer.write('passive: true,');
            break;
          case EventModifier.nonpassive:
            buffer.write('passive: false,');
            break;
          case EventModifier.capture:
            buffer.write('capture: true');
            break;
          case EventModifier.once:
            buffer.write('once: true,');
            break;
          case EventModifier.self:
            buffer.write('onlySelf: true,');
            break;
          case EventModifier.trusted:
            buffer.write('onlyTrusted: true,');
            break;
        }
      }

      buffer.write(')');
    }

    buffer.write('.listen(');
    callbackForEventHandler(handler);
    buffer.write(');');
  }

  void callbackForEventHandler(EventHandler handler) {
    if (handler.isNoArgsListener) {
      // The handler does not take any arguments, so we have to wrap it in a
      // function that does.
      buffer.write('(_) {(');
      writeDartWithPatchedReferences(handler.listener.expression);
      buffer.write(')();}');
    } else {
      // A tear-off will do
      writeDartWithPatchedReferences(handler.listener.expression);
    }
  }

  void createNode(ReactiveNode node) {
    if (node is ReactiveElement) {
      final known = node.knownElement;

      if (known != null) {
        final type = '$_prefix.${known.className}';

        if (known.instantiable) {
          // Use a direct constructor provided by the Dart SDK
          buffer.write(type);
          if (known.constructorName.isNotEmpty) {
            buffer.write('.${known.constructorName}');
          }

          buffer.write('()');
        } else {
          // Use the newElement helper method from zap
          buffer.write(
              '$_prefix.newElement<$type>(${dartStringLiteral(node.tagName)})');
        }
      } else {
        buffer.write("$_prefix.Element.tag('${node.tagName}')");
      }
    } else if (node is ReactiveText) {
      buffer.write("$_prefix.Text('')");
    } else if (node is ConstantText) {
      buffer.write("$_prefix.Text(${dartStringLiteral(node.text)})");
    } else if (node is SubComponent) {
      buffer
        ..write(node.component.className)
        ..write('(');

      for (final property in node.component.parameters) {
        final name = property.key;
        final actualValue = node.expressions[name];

        if (actualValue == null) {
          buffer.write('null');
        } else {
          // Wrap values in a ZapBox to distinguish between set and absent
          // parameters.
          buffer.write('$_prefix.ZapValue(');
          writeDartWithPatchedReferences(actualValue.expression);
          buffer.write(')');
        }

        buffer.write(',');
      }
      buffer.writeln(')..create()');
    } else if (node is ReactiveIf) {
      buffer
        ..writeln('$_prefix.IfBlock((caseNum) {')
        ..writeln('switch (caseNum) {');

      for (var i = 0; i < node.whens.length; i++) {
        final component = node.whens[i].owningComponent!;
        final name = generator._nameForMisc(component);

        buffer.writeln('case $i: return $name(this);');
      }

      final defaultCase = node.otherwise?.owningComponent;
      if (defaultCase != null) {
        final name = generator._nameForMisc(defaultCase);
        buffer.writeln('default: return $name(this);');
      } else {
        buffer.writeln('default: return null;');
      }

      buffer.writeln('}})..create()');
    } else if (node is ReactiveAsyncBlock) {
      final childClass = generator._nameForMisc(node.fragment.owningComponent!);
      final name = node.fragment.resolvedScope
          .findForSubcomponent(SubcomponentVariableKind.asyncSnapshot)!
          .element
          .name;
      final updateFunction =
          '(fragment, snapshot) => (fragment as $childClass).$name = snapshot';

      final className = node.isStream ? 'StreamBlock' : 'FutureBlock';
      buffer.writeln(
          '$_prefix.$className($childClass(this), $updateFunction)..create()');
    } else {
      throw ArgumentError('Unknown node type: $node');
    }
  }

  void writePropertyAccessors() {
    final variablesThatNeedChanges =
        component.scope.declaredVariables.where((variable) {
      if (variable is DartCodeVariable) {
        return variable.isProperty;
      } else if (variable is SubcomponentVariable) {
        switch (variable.kind) {
          case SubcomponentVariableKind.asyncSnapshot:
            return true;
        }
      } else {
        return false;
      }
    });

    for (final variable in variablesThatNeedChanges) {
      final element = variable.element;
      final type = variable.type.getDisplayString(withNullability: true);
      final name = generator._nameForVar(variable);

      // int get foo => $$_v0;
      buffer
        ..write(type)
        ..write(' get ')
        ..write(element.name)
        ..write(' => ')
        ..write(name)
        ..writeln(';');

      if (variable.isMutable) {
        // set foo (int value) {
        //   if (value != $$_v0) {
        //     $$_v0 = value;
        //     $invalidate(bitmask);
        //   }
        // }
        buffer
          ..writeln('set ${element.name} ($type value) {')
          ..writeln('  if (value != $name) {')
          ..writeln('    $name = value;');
        if (variable.needsUpdateTracking) {
          final update = _DartSourceRewriter(generator, component.scope, 0, '')
              .invalidateExpression(variable.updateBitmask.toString());
          buffer.writeln('    $update');
        }
        buffer
          ..writeln('  }')
          ..writeln('}');
      }
    }
  }

  void writeSetText(ReactiveText target) {
    buffer
      ..write(generator._nameForNode(target))
      ..write('.zapText = ');

    final expression = target.expression;
    if (target.needsToString) {
      // Call .toString() on the result
      buffer.write('(');
      writeDartWithPatchedReferences(expression.expression);
      buffer.write(').toString()');
    } else {
      // No .toString() call necessary, just embed the expression directly.
      writeDartWithPatchedReferences(expression.expression);
    }

    buffer.writeln(';');
  }

  void writeUnchangedDartCode(AstNode node) {
    final source = generator.prepareResult.temporaryDartFile
        .substring(node.offset, node.offset + node.length);
    buffer.write(source);
  }

  void writeDartWithPatchedReferences(AstNode dartCode) {
    final originalCode = generator.prepareResult.temporaryDartFile
        .substring(dartCode.offset, dartCode.offset + dartCode.length);
    final rewriter = _DartSourceRewriter(
        generator, component.scope, dartCode.offset, originalCode);
    dartCode.accept(rewriter);

    buffer.write(rewriter.content);
  }
}

class _ComponentWriter extends _ComponentOrSubcomponentWriter {
  @override
  final Component component;
  final String name;

  _ComponentWriter(this.component, this.name, Generator generator,
      GenerationScope classScope)
      : super(generator, classScope);

  @override
  void write() {
    buffer.writeln('class $name extends $_prefix.ZapComponent {');

    final variablesToInitialize = [];

    // Write variables:
    for (final variable
        in component.scope.declaredVariables.whereType<DartCodeVariable>()) {
      if (!variable.isMutable) buffer.write('final ');

      final name = generator._nameForVar(variable);
      buffer
        ..write(variable.element.type.getDisplayString(withNullability: true))
        ..write(' ')
        ..write(name)
        ..write(';')
        ..writeln(' // ${variable.element.name}');

      variablesToInitialize.add(name);
    }

    // And DOM nodes
    writeNodesAndBlockHelpers();

    // Mutable stream subscriptions are stored as instance variables too
    for (final flow in component.flows) {
      final action = flow.action;
      if (!flow.isOneOffAction && action is RegisterEventHandler) {
        buffer
          ..write('late ')
          ..write('StreamSubscription<$_prefix')
          ..write(action.handler.effectiveEventType)
          ..write('> ')
          ..write(generator._nameForMisc(action.handler))
          ..writeln(';');
      }
    }

    // Write a private constructor taking all variables and elements
    buffer
      ..write(name)
      ..write('._(')
      ..write(variablesToInitialize.map((e) => 'this.$e').join(', '))
      ..writeln(');');

    writeFactory();

    writeCreateMethod();
    writeMountMethod();
    writeRemoveMethod();
    writeUpdateMethod();
    writePropertyAccessors();

    // Write functions that were declared in the component
    for (final statement in component.instanceFunctions) {
      writeDartWithPatchedReferences(statement.functionDeclaration);
    }

    buffer.writeln('}');
  }

  void writeFactory() {
    // Properties can be used in the initialization code, so we create
    // constructor properties for them.
    buffer
      ..write('factory ')
      ..write(name)
      ..write('(');

    final dartVariables =
        component.scope.declaredVariables.whereType<DartCodeVariable>();

    final properties = dartVariables.where((e) => e.isProperty);

    for (final variable in properties) {
      // Wrap properties in a ZapValue so that we can fallback to the default
      // value otherwise. We can't use optional parameters as the default
      // doesn't have to be a constant.
      // todo: Don't do that if the parameter is non-nulallable
      final element = variable.element;
      final innerType = element.type.getDisplayString(withNullability: true);
      final type = '$_prefix.ZapValue<$innerType>?';
      buffer
        ..write(type)
        ..write(r' $')
        ..write(element.name)
        ..write(',');
    }

    buffer.writeln(') {');

    // Write all statements for the initializer
    for (final initializer in component.componentInitializers) {
      if (initializer is InitializeStatement) {
        writeUnchangedDartCode(initializer.dartStatement);
      } else if (initializer is InitializeProperty) {
        // We have the property as $property, wrapped in a nullable
        // ZapValue.
        // So write `<type> variable = $variable != null ? $variable.value : <d>`
        final variable = initializer.variable;
        final element = variable.element;

        buffer
          ..write(variable.type.getDisplayString(withNullability: true))
          ..write(' ')
          ..write(element.name)
          ..write(r' = $')
          ..write(element.name)
          ..write(' != null ? ')
          ..write(r'$')
          ..write(element.name)
          ..write('.value : (');

        final declaration = variable.declaration;
        final defaultExpr =
            declaration is VariableDeclaration ? declaration.initializer : null;
        if (defaultExpr != null) {
          writeUnchangedDartCode(defaultExpr);
        } else {
          // No initializer and no value set -> error
          buffer.write(
              'throw ArgumentError(${dartStringLiteral('Parameter ${element.name} is required!')})');
        }

        buffer.write(');');
      }
    }

    // Write call to constructor.
    buffer.write('return $name._(');

    // Write instantiated variables first
    for (final variable in dartVariables) {
      // Variables are created for initializer statements that appear in the
      // code we've just written.
      buffer
        ..write(variable.element.name)
        ..write(',');
    }

    buffer.writeln(');}');
  }
}

class _SubComponentWriter extends _ComponentOrSubcomponentWriter {
  @override
  final ResolvedSubComponent component;

  _SubComponentWriter(
      this.component, Generator generator, GenerationScope classScope)
      : super(generator, classScope);

  @override
  void write() {
    final name = generator._nameForMisc(component);
    buffer.writeln('class $name extends $_prefix.Fragment {');

    final parent = component.parent!;
    final parentType = parent is Component
        ? generator.component.componentName
        : generator._nameForMisc(parent);

    buffer
      ..writeln('final $parentType $_parentField;')
      ..writeln('$name(this.$_parentField);');

    // Inside subfragments, variables are instiated by the parent component
    // before calling create()

    for (final variable
        in component.scope.declaredVariables.cast<SubcomponentVariable>()) {
      final type = variable.type.getDisplayString(withNullability: true);
      final name = generator._nameForVar(variable);

      switch (variable.kind) {
        case SubcomponentVariableKind.asyncSnapshot:
          buffer.writeln(
              '$type $name = const $_prefix.ZapSnapshot.unresolved(); // ${variable.element.name}');
          break;
      }
    }

    writeNodesAndBlockHelpers();
    writeCreateMethod();
    writeMountMethod();
    writeUpdateMethod();
    writeRemoveMethod();
    writePropertyAccessors();

    buffer.writeln('}');
  }
}

class _DartSourceRewriter extends GeneralizingAstVisitor<void> {
  final Generator generator;
  final ZapVariableScope scope;
  final ZapVariableScope rootScope;

  final int startOffsetInDart;
  int skew = 0;
  String content;

  _DartSourceRewriter(
      this.generator, this.scope, this.startOffsetInDart, this.content)
      : rootScope = generator.component.component.scope;

  /// Replaces the range from [start] with length [originalLength] in the
  /// [content] string.
  ///
  /// The [skew] value is set accordingly so that [start] can refer to the
  /// original offset before making any changes. This only works when
  /// [_replaceRange] is called with increasing, non-overlapping offsets.
  void _replaceRange(int start, int originalLength, String newContent) {
    var actualStart = skew + start - startOffsetInDart;

    content = content.replaceRange(
        actualStart, actualStart + originalLength, newContent);
    skew += newContent.length - originalLength;
  }

  void _replaceNode(SyntacticEntity node, String newContent) {
    _replaceRange(node.offset, node.length, newContent);
  }

  BaseZapVariable? _variableFor(Element? element) {
    ZapVariableScope? scope = this.scope;

    while (scope != null) {
      final variable =
          scope.declaredVariables.firstWhereOrNull((v) => v.element == element);
      if (variable != null) {
        return variable;
      }

      scope = scope.parent;
    }
  }

  /// Writes Dart code necessary to access variables defined in the
  /// [targetScope].
  ///
  /// When the [targetScope] is the current [scope], the result will be empty.
  /// When its a parent of the current scope, the result would be `parent.`.
  /// For scopes further up, `parent.` would be repeated.
  String _prefixFor(ZapVariableScope targetScope, {bool trailingDot = true}) {
    var current = scope;
    final result = StringBuffer();

    while (current != targetScope) {
      if (result.isNotEmpty) {
        result.write('.');
      }

      result.write(_parentField);
      current = current.parent!;
    }

    if (trailingDot && result.isNotEmpty) {
      result.write('.');
    }

    return result.toString();
  }

  String invalidateExpression(String bitmaskCode) {
    if (scope == rootScope) {
      return '\$invalidate($bitmaskCode);';
    } else {
      final prefix = _prefixFor(rootScope);
      return '$prefix.\$invalidateSubcomponent(this, $bitmaskCode);';
    }
  }

  void _visitCompoundAssignmentExpression(CompoundAssignmentExpression node) {
    final target = node.writeElement;
    final variable = _variableFor(target);
    final notifyUpdate = variable != null && variable.needsUpdateTracking;

    // Wrap the assignment in an $invalidateAssign block so that it can still
    // be used as an expression while also scheduling a node update!
    if (notifyUpdate) {
      final updateCode = variable!.updateBitmask;

      if (scope == rootScope) {
        _replaceRange(node.offset, 0, '\$invalidateAssign($updateCode, ');
      } else {
        final prefix = _prefixFor(rootScope);
        _replaceRange(node.offset, 0,
            '$prefix.\$invalidateAssignSubcomponent(this, $updateCode, ');
      }
    }

    node.visitChildren(this);

    if (notifyUpdate) {
      _replaceRange(node.offset + node.length, 0, ')');
    }
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    _visitCompoundAssignmentExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    _visitCompoundAssignmentExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    _visitCompoundAssignmentExpression(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final target = node.staticElement;
    final variable = _variableFor(target);

    if (variable is SelfReference) {
      // Inside the main component, we can replace `self` with `this`. In
      // inner components, we have to walk the parent.

      if (rootScope == scope) {
        _replaceNode(node, 'this');
      } else {
        final prefix = _prefixFor(rootScope, trailingDot: false);
        _replaceNode(node, prefix);
      }
    } else if (target is FunctionElement) {
      final newName = generator._nameForFunction(target);
      final prefix = _prefixFor(rootScope);

      _replaceNode(node, '$prefix$newName');
    } else if (variable != null) {
      final prefix = _prefixFor(variable.scope);
      final name = generator._nameForVar(variable);

      final replacement = '$prefix$name /* ${node.name} */';
      _replaceNode(node, replacement);
    }
  }
}

extension on ReactiveNode {
  String? get dartTypeName {
    final $this = this;

    if ($this is ReactiveElement) {
      final known = $this.knownElement;
      return known != null ? '$_prefix.${known.className}' : '$_prefix.Element';
    } else if ($this is ReactiveText || $this is ConstantText) {
      return '$_prefix.Text';
    } else if ($this is SubComponent) {
      return $this.component.className;
    } else if ($this is ReactiveIf) {
      return '$_prefix.IfBlock';
    } else if ($this is ReactiveAsyncBlock) {
      final innerType = $this.type.getDisplayString(withNullability: true);

      return $this.isStream
          ? '$_prefix.StreamBlock<$innerType>'
          : '$_prefix.FutureBlock<$innerType>';
    }
  }
}
