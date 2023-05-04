import React, { useMemo, useCallback, useState, useEffect } from 'react';
import ReactFlow, { Node, ReactFlowProvider, applyEdgeChanges, applyNodeChanges } from 'react-flow-renderer';
import layout, { animate } from './layout'
import nodeTypes from './nodes';
import { Workflow } from './types';
import addPlaceholder from './util/add-placeholder';
import fromWorkflow from './util/from-workflow';

type WorkflowDiagramProps = {
  workflow: Workflow;
  onNodeSelected: (id: string) => void;
}

// Not sure on the relationship to the store
// I kinda just want the component to do visalusation and fir eevents
// Does it even know about zustand? Any benefit?

// So in controlled mode things get difficult
// the component has to track internal chart state, like selection,
// as well as incoming changes from the server (like node state change)
export default ({ workflow, onSelectionChange }: WorkflowDiagramProps) => {
  const [model, setModel] = useState({ nodes: [], edges: [] });

  // TODO can selection just be a flat object? Easier to maintain state this way
  const [selected, setSelected] = useState({ nodes: {}, edges: {} });
  const [flow, setFlow] = useState()

  const setFlowInstance = useCallback((s) => {
    setFlow(s)
  }, [setFlow])

  // Respond to changes pushed into the component from outside
  // This usually means the workflow has changed or its the first load, so we don't want to animate
  // Later, if responding to changes from other users live, we may want to animate
  useEffect(() => {
    const newModel = fromWorkflow(workflow);
    console.log('UPDATING WORKFLOW', workflow);
    setModel(newModel)
    
    // This is rough, but make sure we fit the view after a change
    let t;
    if (flow) {
      t = setTimeout(() => {
        flow.fitView({ duration: 250 });
      }, 50);
    }

    return () => {
      clearTimeout(t);
    }
  }, [workflow])
  
  const onNodesChange = useCallback(
    (changes) => {
      const newNodes = applyNodeChanges(changes, model.nodes);
      setModel({ nodes: newNodes, edges: model.edges });
    }, [setModel, model]);

  const handleNodeClick = useCallback((event: React.MouseEvent, node: Node<NodeData>) => {
    event.stopPropagation();
    if (event.target.closest('[name=add-node]')) {
      const startModel = addPlaceholder(model, node)
      const endModel = layout(startModel)

      animate(startModel, endModel, setModel, flow, 500)
    }
  }, [model])

  const handleSelectionChange = useCallback(({ nodes, edges }) => {
    const everything = nodes.concat(edges);
    const selection = everything.map(({ id }) => id);
    onSelectionChange(selection);
  }, [onSelectionChange]);
  
  return <ReactFlowProvider>
      <ReactFlow
        proOptions={{ account: 'paid-pro', hideAttribution: true }}
        nodes={model.nodes}
        edges={model.edges}
        onSelectionChange={handleSelectionChange}
        onNodesChange={onNodesChange}
        // onEdgesChange={onEdgesChange}
        // // onSelectionChange={onSelectedNodeChange}
        // // onConnect={onConnect}
        // // If we let folks drag, we have to save new visual configuration...
        nodesDraggable={false}
        // // No interaction for this yet...
        // nodesConnectable={false}
        nodeTypes={nodeTypes}
        // snapToGrid={true}
        // snapGrid={[10, 10]}
        onNodeClick={handleNodeClick}
        // onPaneClick={onPaneClick}
        onInit={setFlowInstance}
        fitView
      />
    </ReactFlowProvider>
}