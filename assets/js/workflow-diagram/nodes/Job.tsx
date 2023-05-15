import React, { memo, useState } from 'react';
import { Handle, Position, NodeProps } from 'reactflow';
import Node from './Node';
import PlusButton from './PlusButton';

type NodeData = any;

const JobNode = ({
  targetPosition = Position.Top,
  sourcePosition = Position.Bottom,
  ...props
}: NodeProps<NodeData>) => {
  const toolbar = () => <PlusButton />

  return (<Node
    {...props}
    label={props.data?.label}
    targetPosition={targetPosition}
    sourcePosition={sourcePosition}
    toolbar={toolbar}
  />)
 
};

JobNode.displayName = 'JobNode';

export default memo(JobNode);
